module SpreeWechatPay
  # WeChat Pay gateway, built on core's payment session API.
  #
  # Credentials live in this record's preferences rather than in a
  # `Spree::Integration`, because payments have one credential set per merchant
  # entity and several per store — exactly what payment method rows model
  # (decisions.md, 2026-07-30). An integration's store+type uniqueness would
  # fight that, and a second merchant account is a second record here.
  class Gateway < ::Spree::Gateway
    include SpreeWechatPay::Gateway::PaymentSessions
    include SpreeWechatPay::Gateway::Webhooks

    # WeChat counts in the yuan's minor unit, and the currency travels with the
    # amount rather than being assumed — the conversion to that unit happens
    # once, on the line that hands the amount to WeChat.
    self.accepts_money_amounts = true

    preference :merchant_mode, :string, default: 'direct'
    preference :merchant_id, :string
    preference :merchant_private_key, :password
    preference :merchant_certificate_serial, :string
    preference :api_v3_key, :password
    preference :verification_mode, :string, default: 'public_key'
    preference :wechat_pay_public_key, :password
    preference :wechat_pay_public_key_id, :string
    preference :jsapi_app_id, :string
    preference :jsapi_app_secret, :password
    preference :mini_program_app_id, :string
    preference :mini_program_app_secret, :password
    preference :app_app_id, :string
    # Native and H5 carry no payer identity, but WeChat still requires an
    # `appid` on the request — any of the three kinds, as long as it is bound to
    # the merchant number.
    preference :bound_app_id, :string
    preference :enabled_scenes, :array, of: :string, default: []
    preference :statement_descriptor, :string

    # The identifier each scene needs. Enabling a scene without its identifier
    # is refused here, at configuration time, rather than when the first payment
    # is placed and WeChat rejects the missing `appid`.
    SCENE_IDENTIFIER_PREFERENCES = {
      'jsapi' => :jsapi_app_id,
      'mini_program' => :mini_program_app_id,
      'native' => :bound_app_id,
      'h5' => :bound_app_id,
      'app' => :app_app_id
    }.freeze

    # The fields that name and authenticate the merchant, as opposed to the
    # gateway's settings — its name, its position, whether it is active. Only
    # these are worth a call to WeChat when they move.
    CREDENTIAL_PREFERENCES = %i[
      merchant_mode merchant_id merchant_private_key merchant_certificate_serial api_v3_key
      verification_mode wechat_pay_public_key wechat_pay_public_key_id
      jsapi_app_id jsapi_app_secret mini_program_app_id mini_program_app_secret
      app_app_id bound_app_id
    ].freeze

    # How long a certificate download made while answering a notification may
    # take. WeChat wants an answer within five seconds; this leaves most of that
    # for the verification itself and the response.
    NOTIFICATION_FETCH_TIMEOUT = 2

    validate :validate_credentials, if: :verify_credentials?
    validate :validate_capture_method
    validate :validate_merchant_context, if: :credentials_present?
    validate :validate_merchant_mode
    validate :validate_scene_identifiers

    def provider_class
      self.class
    end

    def default_name
      'WeChat Pay'
    end

    def method_type
      'spree_wechat_pay'
    end

    def payment_icon_name
      'wechat_pay'
    end

    # WeChat issues no reusable instrument for one-off payments, so a payment
    # carries no Spree-side source. Entrusted deduction (委托代扣) is a separate
    # contracting product with its own onboarding, and is not this.
    def source_required?
      false
    end

    def payment_source_class
      nil
    end

    def payment_profiles_supported?
      false
    end

    def setup_session_supported?
      false
    end

    def session_required?
      true
    end

    # WeChat Pay's domestic API settles in yuan alone, so an order in any other
    # currency cannot be paid this way. Without this the payload's hardcoded
    # `CNY` would be attached to another currency's minor units — the same
    # number, a different amount of money.
    #
    # @param order [Spree::Order]
    # @return [Boolean]
    def available_for_order?(order)
      super && order.currency.to_s == 'CNY'
    end

    # @return [SpreeWechatPay::MerchantContext]
    def merchant_context
      MerchantContext.new(
        merchant_id: preferred_merchant_id,
        certificate_serial: preferred_merchant_certificate_serial,
        api_v3_key: preferred_api_v3_key,
        private_key_pem: preferred_merchant_private_key,
        verification_mode: preferred_verification_mode,
        public_key_pem: preferred_wechat_pay_public_key,
        public_key_id: preferred_wechat_pay_public_key_id,
        jsapi_app_id: preferred_jsapi_app_id,
        jsapi_app_secret: preferred_jsapi_app_secret,
        mini_program_app_id: preferred_mini_program_app_id,
        mini_program_app_secret: preferred_mini_program_app_secret,
        app_app_id: preferred_app_app_id,
        bound_app_id: preferred_bound_app_id
      )
    end

    # The merchant this gateway sells under, in WeChat's own number. The mini
    # program passes it straight to the confirm-receipt handshake, so it is
    # publishable rather than secret — WeChat issues it for the client to say.
    #
    # @return [String, nil]
    def merchant_id
      preferred_merchant_id
    end

    # WeChat's own identifier for the transaction a payment recorded, nil until
    # one exists. Read from what {#payment_metadata} wrote onto the payment.
    #
    # @param payment [Spree::Payment]
    # @return [String, nil]
    def transaction_id_for(payment)
      payment.metadata['wechat_pay_transaction_id']
    end

    # WeChat's own identifiers for a transaction, read from WeChat by its
    # merchant order number.
    #
    # The notification core parsed carries the same facts, but core's webhook
    # controller does not pass that metadata through to settlement, so the
    # session reads them back — before the settlement lock, which is where
    # provider I/O belongs.
    #
    # @param merchant_order_number [String]
    # @return [Hash]
    def transaction_metadata_for(merchant_order_number)
      payment_metadata(transaction_for(merchant_order_number).query)
    end

    # Built per call rather than memoized: an operator who corrects a credential
    # expects the next payment to use it, and re-parsing a key costs nothing
    # beside the network call it precedes.
    #
    # @return [SpreeWechatPay::Client]
    def client
      Client.new(context: merchant_context, verifier: -> { verifier })
    end

    # @return [SpreeWechatPay::CertificateStore]
    def certificate_store
      CertificateStore.new(context: merchant_context, client: unverified_client)
    end

    # The keys WeChat's signatures are verified against, by the serial its
    # signature header names.
    #
    # A cold cache is filled here, from a client with the longer timeouts an
    # outgoing call gets — nothing is waiting on a clock the way it is for a
    # notification, which has {#notification_verifier} of its own.
    #
    # @return [SpreeWechatPay::Verifier]
    def verifier
      Verifier.new(certificate_store.verification_keys)
    end

    # The keys a payment notification is verified against.
    #
    # The same set, fetched against a deadline. WeChat requires an answer within
    # five seconds, and a cold cache has to be filled inside that window or the
    # notification cannot be verified at all — which is why the fetch is bounded
    # to one attempt rather than the three an outgoing call allows. WeChat
    # retries a notification it got no answer to, so a fetch that could not
    # finish in time costs a retry rather than the notification.
    #
    # @return [SpreeWechatPay::Verifier]
    def notification_verifier
      Verifier.new(notification_certificate_store.verification_keys)
    end

    # Credits a payment back at WeChat. Core calls this from `Spree::Refund#perform!`
    # with the payment's merchant order number as `transaction_id` and the refund
    # itself as `originator`.
    #
    # WeChat answers with the refund's own `refund_id` and a status. `SUCCESS`
    # and `PROCESSING` both mean the refund is going ahead, so the id is reported
    # as the authorization — core records it on the refund's transaction_id — and
    # the status is written to the refund's metadata for an operator to read.
    # `CLOSED` means the money is not coming back and is refused, so core
    # compensates instead of recording a refund that never happened.
    #
    # @param money [Spree::Money] the amount to refund
    # @param transaction_id [String] the payment's merchant order number
    # @param originator [Spree::Refund] the refund being credited
    # @return [Spree::PaymentResponse]
    def credit(money, transaction_id, originator: nil)
      refund_number = refund_number_for(originator)
      record_refund_number(originator, refund_number)

      response = refund_for(refund_number).create(
        refund_payload(
          out_trade_no: transaction_id,
          out_refund_no: refund_number,
          amount_in_cents: Spree::Money::Rounding.to_minor_units(money.to_d, money.currency),
          payment: originator&.payment
        )
      )

      record_refund_response(originator, response)

      if response['status'] == 'CLOSED'
        raise Spree::Core::GatewayError, I18n.t('spree.wechat_pay.errors.refund_closed')
      end

      Spree::PaymentResponse.new(true, nil, response, authorization: response['refund_id'])
    rescue ApiError => error
      # A definite rejection — WeChat named what is wrong (balance, order state) —
      # surfaced in WeChat's own words rather than as a generic gateway failure.
      raise Spree::Core::GatewayError, error.message
    end

    # Settles a payment for a canceled order.
    #
    # WeChat takes the money at checkout, so there is never an uncaptured
    # authorization for this to release — the only thing left to do with a
    # captured payment is give it back, and only when the operator asked for it.
    #
    # @param transaction_id [String] the payment's merchant order number
    # @param payment [Spree::Payment, nil]
    # @param refund [Boolean] whether money already captured may be returned
    # @return [Spree::PaymentResponse]
    def cancel(transaction_id, payment = nil, refund: true)
      return success_response(transaction_id) unless payment&.completed?
      return success_response(transaction_id) unless refund
      return success_response(transaction_id) if payment.credit_allowed.to_d.zero?

      result = Spree.refund_create_workflow.call(
        payment: payment,
        reason: Spree::RefundReason.order_canceled_reason(payment.owner.store),
        refunder: payment.order&.canceler
      )
      raise Spree::Core::GatewayError, result.error.value.to_s if result.failure?

      success_response(transaction_id, result.value.response&.params)
    end

    # WeChat takes the money at checkout, so a void has no uncaptured
    # authorization to release. Answering success keeps a cancellation or a
    # voided payment from failing against a gateway with nothing to undo.
    #
    # @return [Spree::PaymentResponse]
    def void(_transaction_id, _gateway_options = {})
      Spree::PaymentResponse.new(true, nil, {})
    end

    # Asks WeChat what became of a refund. Nothing in the gem calls this: a
    # refund WeChat reports as `PROCESSING` or `ABNORMAL` has no further
    # outcome recorded on the Spree side, so this is what an operator (or a
    # host's own reconciliation) uses to check one.
    #
    # @param refund_number [String] our `out_refund_no`
    # @return [Hash] the refund as WeChat sees it
    def query_refund(refund_number)
      refund_for(refund_number).query
    end

    # Encrypts a sensitive field WeChat will decrypt with its own private key —
    # the configured WeChat Pay public key, or the latest platform certificate.
    #
    # @param plaintext [String]
    # @return [String] Base64 ciphertext
    def encrypt_sensitive_field(plaintext)
      SensitiveField.encrypt(plaintext, key: sensitive_field_encryption_key)
    end

    # Decrypts a sensitive field WeChat encrypted against the merchant
    # certificate's public key.
    #
    # @param ciphertext [String] Base64
    # @return [String] the plaintext
    def decrypt_sensitive_field(ciphertext)
      SensitiveField.decrypt(ciphertext, key: merchant_context.private_key)
    end

    private

    # @param authorization [String, nil]
    # @param params [Hash, nil]
    # @return [Spree::PaymentResponse]
    def success_response(authorization, params = nil)
      Spree::PaymentResponse.new(true, nil, params || {}, authorization: authorization)
    end

    # The one client that does not verify what it is told, because it is the one
    # that fetches the very keys verification needs: a cold certificate cache
    # would otherwise ask for the keys, fetch them, and try to verify that fetch
    # against keys it does not have yet. Every official WeChat Pay SDK carves
    # out the same call for the same reason.
    #
    # The exposure is bounded — the download is the only thing this client is
    # used for, and what it returns is still decrypted with the APIv3 key, which
    # is what proves a genuine certificate set arrived.
    #
    # @return [SpreeWechatPay::Client]
    def unverified_client
      Client.new(context: merchant_context)
    end

    # The store the notification path reads, on a client bounded to WeChat's
    # own deadline and allowed a single attempt at its own download.
    #
    # @return [SpreeWechatPay::CertificateStore]
    def notification_certificate_store
      CertificateStore.new(
        context: merchant_context,
        client: Client.new(
          context: merchant_context,
          open_timeout: NOTIFICATION_FETCH_TIMEOUT,
          read_timeout: NOTIFICATION_FETCH_TIMEOUT,
          read_retries: 0
        )
      )
    end

    # @param merchant_refund_number [String]
    # @return [SpreeWechatPay::Refund]
    def refund_for(merchant_refund_number)
      Refund.new(context: merchant_context, client: client, merchant_refund_number: merchant_refund_number)
    end

    # @return [OpenSSL::PKey::RSA] the key a sensitive field is encrypted with
    def sensitive_field_encryption_key
      if merchant_context.verification_mode == 'public_key'
        OpenSSL::PKey::RSA.new(merchant_context.public_key_pem)
      else
        certificate_store.current_public_key
      end
    end

    # The refund request. `amount.total` is the original order amount (the
    # payment's captured amount), `amount.refund` is what is being given back.
    #
    # `notify_url` is sent even though refund notifications are acknowledged
    # without being acted on: answering them is what stops WeChat retrying.
    def refund_payload(out_trade_no:, out_refund_no:, amount_in_cents:, payment:)
      {
        'out_trade_no' => out_trade_no,
        'out_refund_no' => out_refund_no,
        'notify_url' => webhook_url,
        'amount' => {
          'refund' => amount_in_cents,
          'total' => total_in_cents(payment),
          'currency' => 'CNY'
        }
      }
    end

    def total_in_cents(payment)
      return 0 if payment.blank?

      Spree::Money::Rounding.to_minor_units(payment.amount, payment.currency)
    end

    # The number WeChat knows the refund by.
    #
    # Derived from the payment's merchant order number and the refund's place in
    # that payment's sequence rather than drawn at random, because WeChat treats
    # `out_refund_no` as an idempotency key: a retry after a response was lost
    # must present the same number, or the money goes back twice. A retry
    # rebuilds the count from the same rows and lands on the same number, while
    # a genuine second refund counts one higher.
    #
    # Two refunds of one payment issued at the same moment can still count the
    # same. With different amounts WeChat refuses the second, which is the safe
    # failure; equal amounts are the one case this would under-refund, and no
    # number derived from the rows alone can tell those apart.
    #
    # @param originator [Spree::Refund, nil]
    # @return [String]
    def refund_number_for(originator)
      payment = originator&.payment
      number = payment && "#{payment.transaction_id}-r#{payment.refunds.count}"
      return number if number.present? && MerchantOrderNumber.valid_refund?(number)

      MerchantOrderNumber.generate_refund(originator)
    end

    # The number WeChat knows the refund by, written down before the API call:
    # it is what the merchant platform shows, so a response lost to a timeout
    # still leaves the operator a way to look the refund up.
    def record_refund_number(refund, refund_number)
      return if refund.blank?

      write_refund_metadata(refund, 'wechat_pay_out_refund_no' => refund_number)
    end

    # WeChat's own identifiers for the refund, under the gateway's own names.
    # Written whatever WeChat answered, before the answer is judged: a refund it
    # accepted and later failed, and one it closed outright, are both only
    # findable in the merchant platform by these.
    def record_refund_response(refund, response)
      return if refund.blank? || response.blank?

      write_refund_metadata(refund, {
        'wechat_pay_refund_id' => response['refund_id'],
        'wechat_pay_refund_status' => response['status'],
        'wechat_pay_out_refund_no' => response['out_refund_no']
      }.compact_blank)
    end

    # Straight to the column rather than saved: the refund row belongs to core,
    # and the gateway's own bookkeeping must not make it dirty or run its
    # validations.
    def write_refund_metadata(refund, attributes)
      merged = (refund.metadata || {}).merge(attributes)
      refund.metadata = merged
      refund.update_columns(metadata: merged)
    end

    # WeChat's own identifiers for a transaction, under the gateway's own names.
    # Written to the payment so an operator holding a payment can find it in the
    # merchant platform, where WeChat knows it only by these.
    #
    # @param response [Hash] a query result or a notification resource
    # @return [Hash]
    def payment_metadata(response)
      {
        'wechat_pay_transaction_id' => response['transaction_id'],
        'wechat_pay_trade_state' => response['trade_state'],
        'wechat_pay_out_trade_no' => response['out_trade_no'],
        'wechat_pay_openid' => response.dig('payer', 'openid')
      }.compact_blank
    end

    # WeChat Pay's domestic API offers no general authorize-then-capture split,
    # so a capture method other than `checkout` is a configuration this gateway
    # cannot honour. Rejecting it when the method is saved is the point — a store
    # set to dispatch-capture would otherwise find out when the first dispatch
    # tried to take money that was already taken.
    #
    # Read through `resolved_capture_method`, not the raw column: an unset
    # preference inherits the store's choice, and it is the inherited value that
    # actually applies.
    def validate_capture_method
      return if store.blank?
      return if resolved_capture_method == 'checkout'

      errors.add(:capture_method, :unsupported,
                 message: I18n.t('spree.wechat_pay.errors.capture_method_unsupported'))
    end

    # Only runs once the two fields that name the merchant are present, so a row
    # with nothing filled in stays a draft. Beyond those, the context is the one
    # place that knows what a usable credential set looks like, so it is asked
    # rather than restated here as a second list of presence rules.
    def validate_merchant_context
      context = merchant_context
      return if context.valid?

      # `keep_id_suffix` because the default drops " id": the public key's
      # identifier would be reported as "Public key", the same name as the key
      # itself, leaving the operator no way to tell which one is missing.
      problems = context.errors.map do |error|
        "#{error.attribute.to_s.humanize(keep_id_suffix: true)} #{error.message}"
      end
      errors.add(:base, :incomplete_credentials,
                 message: I18n.t('spree.wechat_pay.errors.incomplete_credentials',
                                  problems: problems.to_sentence))
    end

    # `merchant_mode` exists so a future partner mode does not have to retrofit a
    # preference, but only `direct` is implemented — anything else is refused here
    # rather than left to a `partner_mode?` branch scattered through the payload
    # builders.
    def validate_merchant_mode
      return if preferred_merchant_mode == 'direct'

      errors.add(:base, I18n.t('spree.wechat_pay.errors.merchant_mode_unsupported'))
    end

    # Every enabled scene must carry the identifier it places the order with. A
    # scene that is ticked without one would otherwise fail only when the first
    # payment is placed and WeChat rejects the missing `appid`.
    def validate_scene_identifiers
      Array(preferred_enabled_scenes).each do |scene|
        preference_name = SCENE_IDENTIFIER_PREFERENCES[scene.to_s]
        next if preference_name.nil?

        next if public_send("preferred_#{preference_name}").present?

        # The message is passed as a string rather than a symbol type: a
        # preference is not a column, so a symbol type would make Rails read the
        # attribute value to interpolate it, and that lookup does not exist.
        errors.add(preference_name, I18n.t('spree.wechat_pay.errors.scene_identifier_required', scene: scene))
      end
    end

    def credentials_present?
      preferred_merchant_id.present? && preferred_merchant_private_key.present?
    end

    # Credentials are proved by one authenticated call to WeChat, made only when
    # there is something new to prove: a method being renamed, reordered or
    # deactivated is saved without reaching the network, because an outage must
    # not make a payment method unsavable.
    #
    # Nothing is sent until the set is complete, so a half-filled set is
    # reported by `validate_merchant_context` as what it is rather than as a
    # rejected call.
    def verify_credentials?
      return false if credential_verification_skipped?

      merchant_context.valid? && credentials_changed?
    end

    # The network is never reached from the test environment: every spec that
    # builds a gateway would otherwise make a live call. Specs that drive the
    # check stub this to false.
    def credential_verification_skipped?
      Rails.env.test?
    end

    # Whether the credential fields have moved since this record was saved. Read
    # from a fresh copy rather than from dirty tracking, because the credentials
    # live inside the `preferences` and `secret_preferences` columns beside
    # settings that need no proving.
    #
    # @return [Boolean]
    def credentials_changed?
      return true if new_record?

      stored = self.class.unscoped.find(id)
      CREDENTIAL_PREFERENCES.any? do |name|
        public_send("preferred_#{name}") != stored.public_send("preferred_#{name}")
      end
    end

    # One authenticated call proves what can be proved remotely: that the
    # merchant certificate signs a request WeChat accepts, under a merchant
    # number it knows. On platform certificates it proves the APIv3 key as well,
    # because the certificates come back encrypted with it; a merchant on the
    # WeChat Pay public key has nothing encrypted to read, so their key is first
    # exercised by a notification. Neither mode proves that WeChat can reach
    # *us* — that needs a publicly reachable callback.
    def validate_credentials
      verify_remote_credentials
    rescue ApiError => error
      errors.add(:base, :credentials_rejected,
                 message: I18n.t('spree.wechat_pay.errors.credentials_rejected', message: error.message))
    rescue Aead::Error => error
      # The call was accepted and its body could not be read, which in practice
      # means the APIv3 key is wrong. Named rather than left to bubble: an
      # exception here is a 500 on the settings form, where the operator needs
      # to be told which field to look at.
      errors.add(:base, :api_v3_key_rejected,
                 message: I18n.t('spree.wechat_pay.errors.api_v3_key_rejected', message: error.message))
    rescue ConnectionError
      errors.add(:base, :wechat_pay_unavailable,
                 message: I18n.t('spree.wechat_pay.errors.unavailable'))
    rescue OpenSSL::PKey::RSAError
      errors.add(:base, :invalid_private_key,
                 message: I18n.t('spree.wechat_pay.errors.invalid_private_key'))
    end

    # What proves the credentials depends on how WeChat's own signatures are
    # verified. A merchant on the WeChat Pay public key has no platform
    # certificates to download — asking for them is refused — so the proof is a
    # lookup instead.
    def verify_remote_credentials
      if preferred_verification_mode == 'public_key'
        probe_transaction_lookup
      else
        certificate_store.refresh!
      end
    end

    # A lookup for a transaction that does not exist. `ORDER_NOT_EXIST` is the
    # success: WeChat answers it only to a request whose signature it accepted,
    # made under a merchant number it knows. Nothing else can be read from this
    # call, because the number is fresh on every save.
    def probe_transaction_lookup
      transaction_for(credential_probe_number).query
    rescue ApiError => error
      raise unless error.code == 'ORDER_NOT_EXIST'
    end

    def credential_probe_number
      "credential-probe-#{SecureRandom.alphanumeric(8)}"
    end
  end
end
