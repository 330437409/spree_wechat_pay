module SpreeWechatPay
  # The public keys WeChat's signatures are verified against.
  #
  # Two modes, distinguished by the serial in the `Wechatpay-Serial` header
  # alone: one shaped `PUB_KEY_ID_<digits>` names the merchant's configured
  # public key, and anything else names a platform certificate.
  #
  # Platform certificates rotate with a 24-hour overlap during which WeChat
  # serves both the old and the new one. That overlap dictates the shape of the
  # cache: it is a set keyed by serial and **merged**, never replaced. A refresh
  # that swapped in only what it had just downloaded would drop the certificate
  # still signing in-flight notifications, and verification would fail for hours.
  class CertificateStore
    CACHE_KEY = 'spree_wechat_pay/platform_certificates'.freeze

    # The associated data WeChat fixes for certificate downloads.
    CERTIFICATE_ASSOCIATED_DATA = 'certificate'.freeze

    # @param context [SpreeWechatPay::MerchantContext]
    # @param client [SpreeWechatPay::Client]
    # @param cache [ActiveSupport::Cache::Store] the store the certificates live
    #   in; injected so a host's choice of cache is visible here rather than
    #   discovered through a verification failure
    def initialize(context:, client:, cache: Rails.cache)
      @context = context
      @client = client
      @cache = cache
    end

    # The keys to verify against, for the caller to hand to a Verifier.
    #
    # Reads the cache. A cold cache — the refresh job has not run yet, or the
    # host's cache store does not persist between requests, which `:null_store`
    # makes the normal case in some environments — fetches once, because the
    # alternative is not a slower verification but no verification at all, and
    # WeChat answers an unverifiable notification by retrying it. Concurrent
    # fetches converge: every writer merges into the same set.
    #
    # @return [Hash{String => OpenSSL::PKey::RSA}]
    def verification_keys
      return public_key_keys if @context.verification_mode == 'public_key'

      certificates = cached_certificates
      if certificates.empty?
        refresh!
        certificates = cached_certificates
      end

      certificates.transform_values { |entry| OpenSSL::PKey::RSA.new(entry['pem']) }
    end

    # Fetches WeChat's platform certificates and merges them into the cache.
    #
    # The certificates arrive encrypted with the APIv3 key, so a successful
    # refresh also proves that key works — which is why credential validation
    # uses this same call.
    #
    # @return [Integer] how many certificates are now cached
    def refresh!
      merged = cached_certificates

      fetch_certificates.each do |entry|
        merged[entry['serial_no']] = {
          'pem' => Aead.decrypt(
            envelope: entry['encrypt_certificate'] || {},
            key: @context.api_v3_key
          ),
          'expire_time' => entry['expire_time']
        }
      end

      # A certificate outlives the 24-hour overlap during which WeChat serves it
      # alongside its replacement, so the set is pruned by each entry's own
      # expiry rather than by what the latest download happened to include.
      merged.delete_if { |_serial, entry| expired?(entry['expire_time']) }

      # One write of the whole set, so a reader never observes a half-updated
      # collection.
      @cache.write(CACHE_KEY, merged)
      merged.size
    end

    # The platform certificate's public key to encrypt a sensitive field with:
    # the one that stays valid longest, so WeChat can still decrypt it after a
    # rotation already in flight.
    #
    # @return [OpenSSL::PKey::RSA]
    # @raise [RuntimeError] when no valid certificate is cached and the download
    #   fails
    def current_public_key
      refresh! if cached_certificates.empty?

      entry = cached_certificates.values.
        reject { |candidate| expired?(candidate['expire_time']) }.
        max_by { |candidate| expire_time(candidate['expire_time']) }

      raise 'No valid WeChat Pay platform certificate is cached' if entry.nil?

      OpenSSL::PKey::RSA.new(entry['pem'])
    end

    private

    def public_key_keys
      { @context.public_key_id => OpenSSL::PKey::RSA.new(@context.public_key_pem) }
    end

    def fetch_certificates
      @client.get('/v3/certificates')['data'] || []
    rescue ApiError => error
      # The one failure worth naming: a certificate this merchant cannot
      # download is almost always a wrong APIv3 key or an unbound certificate.
      raise ApiError.new(
        "Could not download WeChat Pay platform certificates: #{error.message}",
        code: error.code, field: error.field, status: error.status
      )
    end

    def cached_certificates
      @cache.read(CACHE_KEY) || {}
    end

    # @param expire_time [String, nil] WeChat's RFC3339 expiry
    # @return [Boolean]
    def expired?(expire_time)
      return false if expire_time.blank?

      Time.iso8601(expire_time) < Time.current
    rescue ArgumentError
      # An unreadable expiry means we cannot tell whether the certificate has
      # lapsed, so it is kept — dropping a still-valid key breaks verification,
      # while keeping a lapsed one merely never matches an incoming serial.
      false
    end

    # @param value [String, nil] WeChat's RFC3339 expiry
    # @return [Time] the parsed expiry, or the epoch when it cannot be read — so
    #   an unreadable expiry sorts last and is never the certificate chosen to
    #   encrypt with
    def expire_time(value)
      return Time.at(0) if value.blank?

      Time.iso8601(value)
    rescue ArgumentError
      Time.at(0)
    end
  end
end
