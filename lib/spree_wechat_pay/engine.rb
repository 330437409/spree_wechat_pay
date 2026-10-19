require 'rails/engine'

module SpreeWechatPay
  class Engine < Rails::Engine
    isolate_namespace Spree
    engine_name 'spree_wechat_pay'

    config.generators do |g|
      g.test_framework :rspec
    end

    # Core assigns the payment method registry in its own after_initialize, so
    # appending has to happen in a later one — engine callbacks run in load
    # order.
    config.after_initialize do
      Rails.application.config.spree.payment_methods << SpreeWechatPay::Gateway
    end
  end
end
