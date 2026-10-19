module SpreeWechatPay
  # Verifies WeChat's signature over a response body or a notification.
  #
  # The string WeChat signs is three lines — timestamp, nonce, raw body — each
  # terminated by a newline including the last. The body must be the bytes as
  # received: any framework that parses and re-serialises it before this point
  # changes what was signed, which is why callers pass `request.raw_post`.
  class Verifier
    # Raised for anything that fails verification. Core turns a
    # `Spree::PaymentMethod::WebhookSignatureError` into a 401, so callers
    # translate rather than letting this escape.
    class InvalidSignature < StandardError; end

    # A signature never expires on its own: nothing in the three-line string
    # says when it stopped applying, so a notification captured today verifies
    # exactly as well tomorrow. WeChat's own rule — refuse anything more than
    # five minutes away from now — is the only thing that bounds a replay.
    #
    # Applied to responses as well as notifications. A response is signed at the
    # moment it is written, so the window is only ever reached on this side by a
    # host whose clock is badly wrong, and a host six minutes out is failing
    # every other dated verification it attempts.
    REPLAY_WINDOW = 5.minutes

    # @param keys [Hash{String => OpenSSL::PKey::RSA, OpenSSL::PKey::PKey}] public
    #   keys by the serial the signature header named
    # @param now [Time, nil] the instant freshness is measured against; injected
    #   so the window is testable without stopping the clock
    def initialize(keys, now: nil)
      @keys = keys
      @now = now
    end

    # @param body [String] the raw body exactly as received
    # @param timestamp [String]
    # @param nonce [String]
    # @param signature [String] Base64
    # @param serial [String] the `Wechatpay-Serial` header value
    # @return [true]
    # @raise [InvalidSignature]
    def verify!(body:, timestamp:, nonce:, signature:, serial:)
      raise InvalidSignature, 'Missing verification headers' if timestamp.blank? || nonce.blank? || signature.blank?

      verify_freshness!(timestamp)

      key = @keys[serial]
      # A serial we hold no key for is the one case worth distinguishing: during
      # a platform certificate rotation it means the refresh job has not caught
      # up, and an operator reading the log needs to know that rather than see a
      # bare "invalid signature".
      raise InvalidSignature, "No verification key for serial #{serial}" if key.blank?

      message = "#{timestamp}\n#{nonce}\n#{body}\n"

      verified = key.verify(
        OpenSSL::Digest.new('SHA256'),
        Base64.strict_decode64(signature),
        message
      )
      raise InvalidSignature, 'Signature does not match' unless verified

      true
    rescue ArgumentError
      # Base64 that does not decode is a malformed request, not a server error.
      raise InvalidSignature, 'Malformed signature encoding'
    end

    private

    def verify_freshness!(timestamp)
      sent_at = Time.zone.at(Integer(timestamp, 10))
      skew = (current_time - sent_at).abs

      return if skew <= REPLAY_WINDOW

      raise InvalidSignature,
            "Timestamp is #{skew.round} seconds away from now, outside the #{REPLAY_WINDOW.inspect} replay window"
    rescue ArgumentError, TypeError
      # Raised here rather than left to the caller's rescue: a timestamp that is
      # not a number is not a signature encoding problem, and saying so would
      # send an operator looking at the wrong header.
      raise InvalidSignature, 'Malformed signature timestamp'
    end

    def current_time
      @now || Time.current
    end
  end
end
