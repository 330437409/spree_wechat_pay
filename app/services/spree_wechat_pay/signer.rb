module SpreeWechatPay
  # WeChat Pay v3 signatures.
  #
  # Two different signatures are produced from the same RSA key, and confusing
  # them is the failure this class exists to prevent: the request signature
  # authorises a call to WeChat, and the launch signature is what the
  # storefront hands to WeChat to start a payment. They sign different strings.
  class Signer
    # The four-line launch string ends differently per scene, and a wrong one
    # produces a payment that silently never starts rather than an error.
    # JSAPI and the mini program sign `prepay_id=<value>`; APP signs the bare
    # identifier.
    PREPAY_ID_PREFIX_SCENES = %w[jsapi mini_program].freeze

    # @param private_key [OpenSSL::PKey::RSA] the merchant certificate's key
    # @param merchant_id [String]
    # @param certificate_serial [String] the merchant certificate's serial
    def initialize(private_key:, merchant_id:, certificate_serial:)
      @private_key = private_key
      @merchant_id = merchant_id
      @certificate_serial = certificate_serial
    end

    # The APP launch parameter set names the merchant as `partnerId`, which is
    # this value.
    attr_reader :merchant_id

    # Value for the `Authorization` header of any v3 request.
    #
    # The signed string is five lines, each terminated by a newline *including
    # the last*: method, absolute path, timestamp, nonce and the request body
    # byte for byte as it will be sent. The path is signed, which is why a
    # partner-mode call is not merely a different URL.
    #
    # @param method [String, Symbol]
    # @param path [String] absolute path, e.g. `/v3/pay/transactions/jsapi`
    # @param body [String] the exact body, or `''` for a GET
    # @return [String]
    def authorization_header(method:, path:, body: '', timestamp: Time.current.to_i, nonce: SecureRandom.hex(16))
      signature = sign(
        [method.to_s.upcase, path, timestamp, nonce, body].join("\n") + "\n"
      )

      parts = [
        %(mchid="#{@merchant_id}"),
        %(nonce_str="#{nonce}"),
        %(signature="#{signature}"),
        %(timestamp="#{timestamp}"),
        %(serial_no="#{@certificate_serial}")
      ]

      "WECHATPAY2-SHA256-RSA2048 #{parts.join(',')}"
    end

    # The `paySign` the storefront passes to WeChat to launch payment. Produced
    # by the merchant, server-side, and it must use the same certificate the
    # order was placed with.
    #
    # @param app_id [String] the application identifier the order was placed with
    # @param prepay_id [String]
    # @param scene [String, Symbol] `jsapi`, `mini_program` or `app`
    # @return [String]
    def launch_signature(app_id:, prepay_id:, scene:, timestamp:, nonce:)
      fourth_line = if PREPAY_ID_PREFIX_SCENES.include?(scene.to_s)
                      "prepay_id=#{prepay_id}"
                    else
                      prepay_id
                    end

      sign([app_id, timestamp, nonce, fourth_line].join("\n") + "\n")
    end

    private

    def sign(message)
      Base64.strict_encode64(
        @private_key.sign(OpenSSL::Digest.new('SHA256'), message)
      )
    end
  end
end
