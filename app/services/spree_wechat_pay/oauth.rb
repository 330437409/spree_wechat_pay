module SpreeWechatPay
  # The payer's identity, which is a different world from the payment API.
  #
  # A different host, no merchant certificate and no v3 signature — a plain GET
  # carrying the application's own appid and secret. Nothing here goes through
  # `Client`, and conflating the two would send a signed request to an endpoint
  # that does not expect one.
  class Oauth
    BASE_URL = 'https://api.weixin.qq.com'.freeze

    # An official account and a mini program exchange a different kind of code,
    # at a different path, under a different parameter name — and a mini
    # program's answer carries a session key as well as the openid. Everything
    # else about the call is identical.
    EXCHANGES = {
      'jsapi' => { path: '/sns/oauth2/access_token', code_param: :code },
      'mini_program' => { path: '/sns/jscode2session', code_param: :js_code }
    }.freeze

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    # @param context [SpreeWechatPay::MerchantContext]
    # @param connection [Faraday::Connection, nil] injected by specs
    def initialize(context:, connection: nil)
      @context = context
      @connection = connection || build_connection
    end

    # @param scene [String, Symbol] `jsapi` or `mini_program`
    # @param code [String] the code the storefront obtained from WeChat
    # @return [String] the payer's openid
    # @raise [SpreeWechatPay::ApiError]
    def openid_for(scene:, code:)
      exchange = EXCHANGES[scene.to_s]
      raise ArgumentError, "No identity exchange is implemented for the #{scene} scene" if exchange.blank?

      response = get(
        exchange[:path],
        appid: @context.app_id_for(scene),
        secret: secret_for(scene),
        exchange[:code_param] => code,
        grant_type: 'authorization_code'
      )

      openid = response['openid']
      if openid.blank?
        raise ApiError.new(
          'WeChat did not return an openid for that authorization code',
          code: response['errcode'].to_s
        )
      end

      openid
    end

    private

    def secret_for(scene)
      scene.to_s == 'mini_program' ? @context.mini_program_app_secret : @context.jsapi_app_secret
    end

    def build_connection
      Faraday.new(url: BASE_URL) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.timeout = READ_TIMEOUT
        faraday.adapter Faraday.default_adapter
      end
    end

    def get(path, params)
      response = @connection.get(path, params)
      payload = parse(response.body)

      # This endpoint answers with an error body regardless of the HTTP status —
      # which the documentation never states, so the status is not consulted at
      # all. Reading it would turn every refusal into "no openid returned", which
      # names nothing an operator can act on.
      if payload['errcode'].present? && payload['errcode'].to_i != 0
        raise ApiError.new(explain(payload['errcode'].to_s, payload['errmsg']),
                           code: payload['errcode'].to_s, status: response.status)
      end

      payload
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => error
      raise ConnectionError, "WeChat could not be reached (#{error.class.name.demodulize})"
    end

    # The codes that mean different things to different people. A spent or
    # expired code is the customer's to fix; a rejected appid or secret is the
    # merchant's, and saying so saves a support round trip.
    def explain(code, message)
      case code
      when '40029', '40163', '42003'
        "The WeChat authorization code was no longer usable (#{message}). " \
          'A code is single use and expires after five minutes, so the customer needs to start the payment again.'
      when '40013', '40001', '40125', '41002', '41004', '41008'
        "WeChat rejected the application credentials (#{message}). " \
          'Check that the AppID and AppSecret belong to the same account.'
      when '-1'
        "WeChat was too busy to answer (#{message}). Try again."
      else
        message.presence || 'WeChat refused the authorization'
      end
    end

    def parse(body)
      raise ConnectionError, 'WeChat answered with a body that is not JSON' if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      raise ConnectionError, 'WeChat answered with a body that is not JSON'
    end
  end
end
