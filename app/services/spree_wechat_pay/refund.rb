module SpreeWechatPay
  # WeChat refund operations, addressed by our merchant refund number.
  #
  # The refund API is a different path from the transaction API, so it lives
  # beside {SpreeWechatPay::Transaction} rather than inside it.
  class Refund
    REFUND_PATH = '/v3/refund/domestic/refunds'.freeze

    # @param context [SpreeWechatPay::MerchantContext]
    # @param client [SpreeWechatPay::Client]
    # @param merchant_refund_number [String] our `out_refund_no`
    def initialize(context:, client:, merchant_refund_number:)
      @context = context
      @client = client
      @merchant_refund_number = merchant_refund_number
    end

    # Submits the refund. WeChat answers with the refund's own `refund_id` and
    # its current `status`, which is `PROCESSING` while the money is still
    # moving rather than a completion.
    #
    # @param payload [Hash]
    # @return [Hash] carries `refund_id` and the refund's current `status`
    def create(payload)
      @client.post(REFUND_PATH, payload)
    end

    # @return [Hash] the refund as WeChat sees it
    # @raise [SpreeWechatPay::ApiError] `RESOURCE_NOT_EXISTS` when nothing was
    #   ever created under this number
    def query
      @client.get("#{REFUND_PATH}/#{CGI.escape(@merchant_refund_number)}")
    end
  end
end
