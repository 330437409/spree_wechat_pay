FactoryBot.define do
  # One key pair per process. A gateway needs readable PEMs, and generating
  # 2048-bit keys for every record would cost more than the record does.
  merchant_key = OpenSSL::PKey::RSA.new(2048)
  platform_key = OpenSSL::PKey::RSA.new(2048)

  factory :wechat_pay_gateway, parent: :payment_method, class: 'SpreeWechatPay::Gateway' do
    sequence(:name) { |n| "WeChat Pay #{n}" }
    type { 'SpreeWechatPay::Gateway' }

    preferences do
      {
        merchant_id: '1900000001',
        merchant_private_key: merchant_key.to_pem,
        merchant_certificate_serial: '5157F09EFDC096DE15EBE81A47057A72',
        api_v3_key: 'abcdefghijklmnopqrstuvwxyz012345',
        verification_mode: 'public_key',
        wechat_pay_public_key: platform_key.public_key.to_pem,
        wechat_pay_public_key_id: 'PUB_KEY_ID_3000000000000024101100397200000006',
        bound_app_id: 'wx_bound_appid',
        enabled_scenes: ['native']
      }
    end

    trait :with_jsapi_scene do
      preferences do
        {
          merchant_id: '1900000001',
          merchant_private_key: merchant_key.to_pem,
          merchant_certificate_serial: '5157F09EFDC096DE15EBE81A47057A72',
          api_v3_key: 'abcdefghijklmnopqrstuvwxyz012345',
          verification_mode: 'public_key',
          wechat_pay_public_key: platform_key.public_key.to_pem,
          wechat_pay_public_key_id: 'PUB_KEY_ID_3000000000000024101100397200000006',
          jsapi_app_id: 'wx_jsapi_appid',
          jsapi_app_secret: 'jsapi_app_secret_value',
          enabled_scenes: %w[jsapi]
        }
      end
    end
  end
end
