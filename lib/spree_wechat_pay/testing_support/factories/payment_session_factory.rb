FactoryBot.define do
  factory :wechat_pay_payment_session, class: 'Spree::PaymentSessions::WechatPay' do
    transient do
      owner { create(:order_with_line_items) }
    end

    cart { owner if owner.is_a?(Spree::Cart) }
    order { owner unless owner.is_a?(Spree::Cart) }
    payment_method { create(:wechat_pay_gateway, store: owner.store) }
    amount { owner.total }
    currency { 'CNY' }
    status { 'pending' }
    # Our merchant order number, not WeChat's transaction id: it exists from the
    # moment the transaction is asked for, and it is what a refund is addressed by.
    external_id { "R#{SecureRandom.alphanumeric(10).upcase}-#{SecureRandom.alphanumeric(8)}" }
    external_data do
      {
        'scene' => 'native',
        'payload_expires_at' => 2.hours.from_now.iso8601
      }
    end

    trait :completed do
      status { 'completed' }
    end

    trait :failed do
      status { 'failed' }
    end
  end
end
