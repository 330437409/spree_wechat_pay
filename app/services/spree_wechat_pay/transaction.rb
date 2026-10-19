module SpreeWechatPay
  # One WeChat Pay transaction, addressed by our merchant order number.
  #
  # Everything the gateway does to a transaction — create it, ask what happened
  # to it, close it — goes through here, so the endpoint shapes and the state
  # vocabulary live in one place rather than in each scene.
  class Transaction
    # The customer is in WeChat's payment sheet: the money is on its way but has
    # not arrived. Neither settled nor safe to retire — closing the transaction
    # now would abort the payment being made through it.
    PAYING_STATES = %w[USERPAYING].freeze
    # Funds have moved. REFUND means they moved and were given back; the payment
    # itself was real either way.
    PAID_STATES = %w[SUCCESS REFUND].freeze
    # Terminal without payment.
    CLOSED_STATES = %w[CLOSED REVOKED].freeze
    # Only the barcode scene produces this.
    FAILED_STATES = %w[PAYERROR].freeze

    # @param context [SpreeWechatPay::MerchantContext]
    # @param client [SpreeWechatPay::Client]
    # @param merchant_order_number [String]
    def initialize(context:, client:, merchant_order_number:)
      @context = context
      @client = client
      @merchant_order_number = merchant_order_number
    end

    attr_reader :merchant_order_number

    # Places the transaction. The caller supplies the payload because its shape
    # is what differs between scenes; the path does not.
    #
    # @param scene [String, Symbol]
    # @param payload [Hash]
    # @return [Hash] the scene's response — `code_url` for Native, `prepay_id`
    #   for the rest
    def create(scene:, payload:)
      @client.post(@context.transaction_path(scene), payload)
    end

    # @return [Hash] the transaction as WeChat sees it
    # @raise [SpreeWechatPay::ApiError] `ORDER_NOT_EXIST` when nothing was ever
    #   created under this number, which is what a lost create response looks
    #   like from here
    def query
      @client.get(query_path)
    end

    # @return [Hash]
    def close
      @client.post("#{base_path}/close", { 'mchid' => @context.merchant_id })
    end

    # @param response [Hash] a query or notification payload
    # @return [Boolean]
    def self.paid?(response)
      PAID_STATES.include?(response['trade_state'])
    end

    # @param response [Hash]
    # @return [Boolean]
    def self.paying?(response)
      PAYING_STATES.include?(response['trade_state'])
    end

    # @param response [Hash]
    # @return [Boolean]
    def self.closed?(response)
      CLOSED_STATES.include?(response['trade_state'])
    end

    private

    def base_path
      "/v3/pay/transactions/out-trade-no/#{escape(@merchant_order_number)}"
    end

    # The query string is part of what gets signed, so it is built here and
    # handed to the client as one string — a caller that signed the bare path
    # and sent a different URL would be refused.
    def query_path
      "#{base_path}?mchid=#{escape(@context.merchant_id)}"
    end

    def escape(value)
      CGI.escape(value.to_s)
    end
  end
end
