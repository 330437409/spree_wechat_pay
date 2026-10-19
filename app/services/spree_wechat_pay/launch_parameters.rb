module SpreeWechatPay
  # What the storefront hands to WeChat to start a payment.
  #
  # The signature is produced here, on the server. The browser never sees the
  # private key, and the storefront never implements signing — it receives a
  # finished parameter set and passes it through. Getting this wrong produces a
  # payment that silently does not start, with nothing reported anywhere, so the
  # per-scene differences are held in one place and tested directly.
  class LaunchParameters
    # `signType` does not take part in the signature but must still be sent.
    SIGN_TYPE = 'RSA'.freeze

    def initialize(signer:, scene:, app_id:, prepay_id:, timestamp: nil, nonce: nil)
      @signer = signer
      @scene = scene.to_s
      @app_id = app_id
      @prepay_id = prepay_id
      @timestamp = (timestamp || Time.current.to_i).to_s
      @nonce = nonce || SecureRandom.alphanumeric(32)
    end

    # @return [Hash] the parameter set for the scene's launch call
    def to_h
      case @scene
      when 'jsapi' then jsapi
      # Same signed string, same fields but one: the mini program's launch call
      # carries no `appId`, because its own identifier is implicit. Sending it
      # anyway is not an error WeChat reports — the payment simply does not
      # start — so the difference is kept here rather than left to a caller.
      when 'mini_program' then jsapi.except('appId')
      # The APP launch call is a different field set, signed over the bare
      # prepay id rather than `prepay_id=<value>`.
      when 'app' then app_params
      else
        raise ArgumentError, "No launch parameters are implemented for the #{@scene} scene yet"
      end
    end

    private

    def jsapi
      {
        'appId' => @app_id,
        'timeStamp' => @timestamp,
        'nonceStr' => @nonce,
        # The docs' own spelling: `package` holds `prepay_id=<value>`.
        'package' => "prepay_id=#{@prepay_id}",
        'signType' => SIGN_TYPE,
        'paySign' => signature
      }
    end

    # The APP SDK's `PayReq`: the merchant as `partnerId`, the prepay id bare,
    # and a fixed `package`. The docs name this field `packageValue` for Android
    # and `package` for iOS — the storefront maps it to whichever SDK it drives.
    def app_params
      {
        'appId' => @app_id,
        'partnerId' => @signer.merchant_id,
        'prepayId' => @prepay_id,
        'package' => 'Sign=WXPay',
        'nonceStr' => @nonce,
        'timeStamp' => @timestamp,
        'sign' => signature
      }
    end

    def signature
      @signer.launch_signature(
        app_id: @app_id,
        prepay_id: @prepay_id,
        scene: @scene,
        timestamp: @timestamp,
        nonce: @nonce
      )
    end
  end
end
