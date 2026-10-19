module SpreeWechatPay
  class BaseJob < Spree::BaseJob
    queue_as { SpreeWechatPay.queue }
  end
end
