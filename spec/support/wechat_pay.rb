# A locally generated RSA key pair stands in for the merchant certificate and
# for WeChat's own key. Nothing here needs a merchant account: signing and
# verification are arithmetic, and proving them is the point of these specs —
# a recorded cassette proves the payload shapes, not that the signature is
# computed correctly.
module WechatPaySpecHelpers
  MERCHANT_SERIAL = '5157F09EFDC096DE15EBE81A47057A72'.freeze
  PLATFORM_SERIAL = '2F1B0F8A2C3D4E5F60718293A4B5C6D7'.freeze
  PUBLIC_KEY_ID = 'PUB_KEY_ID_3000000000000024101100397200000006'.freeze
  MERCHANT_ID = '1900000001'.freeze
  API_V3_KEY = 'abcdefghijklmnopqrstuvwxyz012345'.freeze
  BOUND_APP_ID = 'wx_bound_appid'.freeze
  JSAPI_APP_SECRET = 'jsapi_app_secret_value'.freeze
  MINI_PROGRAM_APP_SECRET = 'mini_program_app_secret_value'.freeze

  def merchant_key_pair
    @merchant_key_pair ||= OpenSSL::PKey::RSA.new(2048)
  end

  def platform_key_pair
    @platform_key_pair ||= OpenSSL::PKey::RSA.new(2048)
  end

  def merchant_context(overrides = {})
    SpreeWechatPay::MerchantContext.new(
      {
        merchant_id: MERCHANT_ID,
        certificate_serial: MERCHANT_SERIAL,
        api_v3_key: API_V3_KEY,
        private_key_pem: merchant_key_pair.to_pem,
        verification_mode: 'public_key',
        public_key_pem: platform_key_pair.public_key.to_pem,
        public_key_id: PUBLIC_KEY_ID,
        jsapi_app_id: 'wx_jsapi_appid',
        jsapi_app_secret: JSAPI_APP_SECRET,
        mini_program_app_id: 'wx_mini_appid',
        mini_program_app_secret: MINI_PROGRAM_APP_SECRET,
        app_app_id: 'wx_app_appid',
        bound_app_id: BOUND_APP_ID
      }.merge(overrides)
    )
  end

  # Signs the way WeChat does, so the verifier can be exercised against
  # something other than itself.
  def sign_like_wechat(message, key: platform_key_pair)
    Base64.strict_encode64(key.sign(OpenSSL::Digest.new('SHA256'), message))
  end

  # Encrypts the way WeChat does. Round-tripping through our own encryption is
  # not proof on its own, so the specs also assert against a fixed vector whose
  # plaintext is known independently.
  def encrypt_like_wechat(plaintext, key: API_V3_KEY, associated_data: 'transaction')
    nonce = SecureRandom.alphanumeric(12)
    cipher = OpenSSL::Cipher.new('aes-256-gcm')
    cipher.encrypt
    cipher.key = key
    cipher.iv = nonce
    cipher.auth_data = associated_data
    ciphertext = cipher.update(plaintext) + cipher.final

    {
      'algorithm' => 'AEAD_AES_256_GCM',
      'ciphertext' => Base64.strict_encode64(ciphertext + cipher.auth_tag),
      'nonce' => nonce,
      'associated_data' => associated_data
    }
  end

  # WeChat Pay is domestic and settles in yuan only, and Spree refuses a cart in
  # a currency its store does not support — so the store has to accept CNY for
  # any of this to be reachable.
  def wechat_store
    @wechat_store ||= create(:store, default_currency: 'CNY', supported_currencies: 'CNY,USD')
  end

  # A saved gateway with a full credential set. `validate_credentials` does not
  # run in the test environment, so saving never reaches the network.
  def wechat_gateway(**preferences)
    # Not a fixed name: a store refuses a second gateway under the same one, and
    # the job's specs deliberately build two — one failing, one healthy.
    @wechat_gateway_sequence = (@wechat_gateway_sequence || 0) + 1
    gateway = SpreeWechatPay::Gateway.new(store: wechat_store, name: "WeChat Pay #{@wechat_gateway_sequence}", active: true)
    gateway.preferred_merchant_id = MERCHANT_ID
    gateway.preferred_merchant_private_key = merchant_key_pair.to_pem
    gateway.preferred_merchant_certificate_serial = MERCHANT_SERIAL
    gateway.preferred_api_v3_key = API_V3_KEY
    gateway.preferred_verification_mode = 'public_key'
    gateway.preferred_wechat_pay_public_key = platform_key_pair.public_key.to_pem
    gateway.preferred_wechat_pay_public_key_id = PUBLIC_KEY_ID
    gateway.preferred_bound_app_id = BOUND_APP_ID
    gateway.preferred_jsapi_app_id = 'wx_jsapi_appid'
    gateway.preferred_jsapi_app_secret = JSAPI_APP_SECRET
    gateway.preferred_mini_program_app_id = 'wx_mini_appid'
    gateway.preferred_mini_program_app_secret = MINI_PROGRAM_APP_SECRET
    gateway.preferred_app_app_id = 'wx_app_appid'
    gateway.preferred_enabled_scenes = ['native']

    preferences.each { |key, value| gateway.public_send("preferred_#{key}=", value) }
    gateway.save!
    gateway
  end

  def wechat_cart(total: 12.34)
    cart = create(:cart, store: wechat_store, currency: 'CNY')
    create(:line_item, cart: cart, order: nil, price: total, quantity: 1)
    cart.recalculate_totals!
    cart
  end

  # A gateway whose provider calls are answered from a hash of canned responses
  # keyed by path, so the specs never reach WeChat.
  def gateway_with_client(gateway, responses)
    client = instance_double(SpreeWechatPay::Client)
    responses.each do |path, response|
      if response.is_a?(StandardError)
        allow(client).to receive(:post).with(path, anything).and_raise(response)
        allow(client).to receive(:get).with(path, any_args).and_raise(response)
      else
        allow(client).to receive(:post).with(path, anything).and_return(response)
        allow(client).to receive(:get).with(path, any_args).and_return(response)
      end
    end
    allow(gateway).to receive(:client).and_return(client)
    client
  end
end

RSpec.configure do |config|
  config.include WechatPaySpecHelpers
end
