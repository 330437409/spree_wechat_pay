require 'spec_helper'

RSpec.describe SpreeWechatPay::Gateway do
  let(:store) { create(:store) }
  let(:gateway) { described_class.new(store: store, name: 'WeChat Pay') }

  it 'registers itself as a payment provider' do
    expect(Spree.payment_methods.map(&:to_s)).to include('SpreeWechatPay::Gateway')
  end

  # The wire type the admin and the API use. Derived from the outer module
  # because the demodulized leaf collapses every gateway to `gateway`.
  it 'reports a distinct api_type' do
    expect(described_class.api_type).to eq('wechat_pay')
  end

  it 'names itself' do
    expect(described_class.new.default_name).to eq('WeChat Pay')
  end

  # The factories the gem ships for host apps and other extensions. This suite
  # loads them too, so a broken one fails here rather than in someone else's
  # build.
  describe 'factories' do
    it 'builds a gateway with a complete credential set' do
      gateway = create(:wechat_pay_gateway, store: store)

      expect(gateway).to be_persisted
      expect(gateway.merchant_context).to be_valid
      expect(gateway.preferred_enabled_scenes).to eq(['native'])
    end

    it 'builds a pending session addressed by our merchant order number' do
      session = create(:wechat_pay_payment_session)

      expect(session).to be_persisted
      expect(session).to be_pending
      expect(session.scene).to eq('native')
      expect(SpreeWechatPay::MerchantOrderNumber.valid?(session.merchant_order_number)).to be true
    end
  end

  # What a mini program's confirm-receipt handshake needs from the gateway: the
  # merchant it sells under, and its own id for the transaction.
  describe 'the confirm-receipt identifiers' do
    it 'answers the merchant it sells under' do
      gateway.preferred_merchant_id = '1900000109'

      expect(gateway.merchant_id).to eq('1900000109')
    end

    it 'answers the transaction id a payment recorded' do
      payment = build(:payment, metadata: { 'wechat_pay_transaction_id' => '420000123420260920' })

      expect(gateway.transaction_id_for(payment)).to eq('420000123420260920')
    end

    it 'has no transaction id before WeChat has named one' do
      expect(gateway.transaction_id_for(build(:payment, metadata: {}))).to be_nil
    end
  end

  describe 'capabilities' do
    it 'always goes through a payment session' do
      expect(gateway.session_required?).to be true
    end

    # Core hands the amount over as `Spree::Money`, the way `spree_stripe` does
    # and the money rules require. Taking hundredths instead would lose the
    # currency and deprecate on every call.
    it 'takes amounts as money rather than as hundredths' do
      expect(gateway.accepts_money_amounts).to be true
      expect(gateway.gateway_amount(BigDecimal('5'), 'CNY')).to be_a(Spree::Money)
    end

    # Nothing here sends an amount in a currency WeChat will not settle, so a
    # store in another currency must not be offered the method at all.
    it 'is offered only for orders in yuan' do
      order = build(:order, currency: 'USD')

      expect(gateway.available_for_order?(order)).to be false
    end

    it 'is offered for an order in yuan' do
      order = build(:order, currency: 'CNY')

      expect(gateway.available_for_order?(order)).to be true
    end

    it 'holds no reusable customer instrument' do
      expect(gateway.source_required?).to be false
      expect(gateway.payment_source_class).to be_nil
      expect(gateway.payment_profiles_supported?).to be false
      expect(gateway.setup_session_supported?).to be false
    end
  end

  describe 'capture method' do
    it 'accepts capture at checkout' do
      gateway.capture_method = 'checkout'

      expect(gateway).to be_valid
    end

    # WeChat offers no general authorize-then-capture split, so this is a
    # configuration the gateway cannot keep. Rejecting it when the method is
    # saved is the point: the alternative is discovering it when a dispatch
    # tries to take money that was already taken.
    it 'refuses a capture method it cannot honour' do
      gateway.capture_method = 'on_dispatch'

      expect(gateway).not_to be_valid
      expect(gateway.errors.attribute_names).to include(:capture_method)
    end

    it 'refuses an inherited capture method it cannot honour' do
      allow(gateway).to receive(:resolved_capture_method).and_return('manual')

      expect(gateway).not_to be_valid
      expect(gateway.errors.attribute_names).to include(:capture_method)
    end

    it 'names the problem rather than saying the value is invalid' do
      gateway.capture_method = 'manual'
      gateway.valid?

      expect(gateway.errors[:capture_method].first).to include('capture at checkout')
    end
  end

  describe 'merchant mode' do
    before { gateway.capture_method = 'checkout' }

    it 'accepts direct mode' do
      gateway.preferred_merchant_mode = 'direct'

      expect(gateway).to be_valid
    end

    # `merchant_mode` is a future-compatibility preference, not a capability:
    # only direct is implemented, so anything else is refused plainly rather
    # than branched on later.
    it 'refuses a mode that is not direct' do
      gateway.preferred_merchant_mode = 'partner'

      expect(gateway).not_to be_valid
      expect(gateway.errors[:base].join).to include('direct')
    end
  end

  describe 'scene identifiers' do
    before { gateway.capture_method = 'checkout' }

    it 'accepts a scene that carries its identifier' do
      gateway.preferred_enabled_scenes = ['native']
      gateway.preferred_bound_app_id = 'wx_bound_appid'

      expect(gateway).to be_valid
    end

    # A scene ticked without its identifier would otherwise fail only when the
    # first payment is placed and WeChat rejects the missing appid.
    it 'refuses Native without a bound application identifier' do
      gateway.preferred_enabled_scenes = ['native']

      expect(gateway).not_to be_valid
      expect(gateway.errors.attribute_names).to include(:bound_app_id)
    end

    it 'refuses H5 without a bound application identifier' do
      gateway.preferred_enabled_scenes = ['h5']

      expect(gateway).not_to be_valid
      expect(gateway.errors.attribute_names).to include(:bound_app_id)
    end

    it 'refuses APP without its application identifier' do
      gateway.preferred_enabled_scenes = ['app']

      expect(gateway).not_to be_valid
      expect(gateway.errors.attribute_names).to include(:app_app_id)
    end

    it 'refuses JSAPI without its application identifier' do
      gateway.preferred_enabled_scenes = ['jsapi']

      expect(gateway).not_to be_valid
      expect(gateway.errors.attribute_names).to include(:jsapi_app_id)
    end

    it 'names the scene that is missing its identifier' do
      gateway.preferred_enabled_scenes = ['native']
      gateway.valid?

      expect(gateway.errors[:bound_app_id].first).to include('native')
    end

    it 'ignores a scene outside the known vocabulary' do
      gateway.preferred_enabled_scenes = ['micropay']

      expect(gateway).to be_valid
    end
  end

  describe 'credentials' do
    it 'builds a merchant context from its preferences' do
      gateway.preferred_merchant_id = WechatPaySpecHelpers::MERCHANT_ID

      expect(gateway.merchant_context.merchant_id).to eq(WechatPaySpecHelpers::MERCHANT_ID)
    end

    # An empty row is a draft an operator can come back to. A half-filled one is
    # a mistake, and it is refused while it is still on screen rather than when
    # the first customer tries to pay.
    it 'allows a payment method with no credentials yet' do
      draft = described_class.new(store: store, name: 'WeChat Pay')
      draft.capture_method = 'checkout'

      expect(draft).to be_valid
    end

    it 'refuses a half-filled credential set' do
      gateway.capture_method = 'checkout'
      gateway.preferred_merchant_id = WechatPaySpecHelpers::MERCHANT_ID
      gateway.preferred_merchant_private_key = merchant_key_pair.to_pem
      gateway.preferred_merchant_certificate_serial = WechatPaySpecHelpers::MERCHANT_SERIAL

      expect(gateway).not_to be_valid
      expect(gateway.errors[:base].join).to include('Api v3 key')
    end

    it 'refuses public key mode without WeChat Pay’s own public key' do
      gateway.capture_method = 'checkout'
      gateway.preferred_merchant_id = WechatPaySpecHelpers::MERCHANT_ID
      gateway.preferred_merchant_private_key = merchant_key_pair.to_pem
      gateway.preferred_merchant_certificate_serial = WechatPaySpecHelpers::MERCHANT_SERIAL
      gateway.preferred_api_v3_key = WechatPaySpecHelpers::API_V3_KEY

      expect(gateway).not_to be_valid
      expect(gateway.errors[:base].join).to include('Public key pem', 'Public key id')
    end

    # Built per call: an operator who corrects a credential expects the next
    # payment to use it.
    it 'reflects a corrected credential on the next call' do
      gateway.preferred_merchant_id = '1900000001'
      first = gateway.merchant_context
      gateway.preferred_merchant_id = '1900000002'

      expect(gateway.merchant_context.merchant_id).to eq('1900000002')
      expect(first.merchant_id).to eq('1900000001')
    end

    it 'checks every answer against WeChat’s signature' do
      allow(SpreeWechatPay::Client).to receive(:new).and_call_original

      gateway.client

      expect(SpreeWechatPay::Client).to have_received(:new).with(hash_including(:verifier))
    end

    # The certificate download cannot be verified against the keys it exists to
    # fetch, so it is the one call made without a verifier.
    it 'downloads certificates with a client that does not verify them' do
      allow(SpreeWechatPay::Client).to receive(:new).and_call_original

      gateway.certificate_store

      expect(SpreeWechatPay::Client).to have_received(:new).with(hash_excluding(:verifier))
    end

    # A notification has to be answered inside WeChat's own five seconds, and a
    # cold cache is filled inside that window or not at all — so the fetch is
    # bounded, and a retry that could not finish in time is not made.
    it 'fetches a notification’s keys on a client bounded to WeChat’s deadline' do
      certified = wechat_gateway
      allow(SpreeWechatPay::Client).to receive(:new).and_call_original

      certified.notification_verifier

      expect(SpreeWechatPay::Client).to have_received(:new).with(
        hash_including(
          open_timeout: SpreeWechatPay::Gateway::NOTIFICATION_FETCH_TIMEOUT,
          read_timeout: SpreeWechatPay::Gateway::NOTIFICATION_FETCH_TIMEOUT,
          read_retries: 0
        )
      )
    end
  end

  # Saving credentials runs one authenticated call. The call is skipped in the
  # test environment, because every spec that builds a gateway would otherwise
  # make a live one, so these lift the skip and stub the transport.
  describe 'credential verification' do
    let(:gateway) { wechat_gateway }

    before { allow(gateway).to receive(:credential_verification_skipped?).and_return(false) }

    # Nothing is sent until the credential set is complete: a half-filled set is
    # reported as what it is, rather than as a call WeChat refused.
    it 'does not reach WeChat for a half-filled credential set' do
      gateway.preferred_api_v3_key = nil

      expect(gateway).not_to receive(:verify_remote_credentials)
      expect(gateway).not_to be_valid
      expect(gateway.errors[:base].join).to include('Api v3 key')
    end

    # An outage must not make a payment method unsavable, so only a change to
    # the credentials is worth a call.
    it 'does not reach WeChat when nothing but a setting changed' do
      gateway.name = 'WeChat Pay CNY'

      expect(gateway).not_to receive(:verify_remote_credentials)
      expect(gateway).to be_valid
    end

    it 'reaches WeChat when a credential changes' do
      gateway.preferred_merchant_id = '1900000002'

      expect(gateway).to receive(:verify_remote_credentials)
      gateway.validate
    end

    # A wrong APIv3 key is the likeliest mistake an operator makes, and it is
    # the answer that cannot be read rather than the call that fails. Letting it
    # bubble is a 500 on the settings form, where the operator needs to be told
    # which field to look at.
    it 'reports an answer it cannot read with the APIv3 key' do
      gateway.preferred_merchant_id = '1900000002'
      allow(gateway).to receive(:verify_remote_credentials).and_raise(
        SpreeWechatPay::Aead::Error.new('Payload could not be decrypted')
      )

      gateway.validate

      expect(gateway.errors[:base].join).to include('APIv3 key')
    end

    # A merchant on the WeChat Pay public key has no platform certificates at
    # all, so asking to download them is refused and a correctly configured
    # store would not save.
    it 'proves the credentials with a transaction lookup in public key mode' do
      gateway.preferred_merchant_id = '1900000002'
      client = instance_double(SpreeWechatPay::Client)
      allow(gateway).to receive(:client).and_return(client)
      allow(client).to receive(:get).and_raise(
        SpreeWechatPay::ApiError.new('订单不存在', code: 'ORDER_NOT_EXIST', status: 404)
      )

      expect(gateway).not_to receive(:certificate_store)
      gateway.validate

      expect(gateway.errors[:base]).to be_empty
    end

    # `ORDER_NOT_EXIST` is the success: WeChat answers it only to a request
    # whose signature it accepted. Any other refusal is the credentials.
    it 'reports a lookup WeChat refused rather than answered' do
      gateway.preferred_merchant_id = '1900000002'
      client = instance_double(SpreeWechatPay::Client)
      allow(gateway).to receive(:client).and_return(client)
      allow(client).to receive(:get).and_raise(
        SpreeWechatPay::ApiError.new('签名错误', code: 'SIGN_ERROR', status: 401)
      )

      gateway.validate

      expect(gateway.errors[:base].join).to include('签名错误')
    end

    it 'downloads platform certificates when those are what verify signatures' do
      gateway.preferred_merchant_id = '1900000002'
      gateway.preferred_verification_mode = 'platform_certificate'
      store = instance_double(SpreeWechatPay::CertificateStore, refresh!: 1)
      allow(gateway).to receive(:certificate_store).and_return(store)

      gateway.validate

      expect(store).to have_received(:refresh!)
      expect(gateway.errors[:base]).to be_empty
    end
  end

  describe '#credit' do
    let(:gateway) { wechat_gateway }
    let(:cart) { wechat_cart }

    let(:payment) do
      session = Spree::PaymentSessions::WechatPay.create!(
        owner: cart, payment_method: gateway, amount: cart.total, currency: 'CNY',
        status: 'pending', external_id: 'R1001-credit'
      )
      session.settle_payment!(captured: true, metadata: {})
    end

    let(:refund) { create(:refund, payment: payment, amount: 5, transaction_id: nil) }

    before do
      client = instance_double(SpreeWechatPay::Client)
      allow(gateway).to receive(:client).and_return(client)
      # WeChat answers with the `out_refund_no` it was given.
      allow(client).to receive(:post) do |_path, payload|
        { 'refund_id' => 'r1', 'out_refund_no' => payload['out_refund_no'], 'status' => 'PROCESSING' }
      end
    end

    it 'submits the refund against the merchant order number and returns WeChat own refund id' do
      response = gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund)

      expect(response).to be_success
      expect(response.authorization).to eq('r1')
      expect(gateway.client).to have_received(:post).with(
        '/v3/refund/domestic/refunds',
        hash_including('out_trade_no' => payment.response_code, 'amount' => hash_including('refund' => 500))
      )
    end

    # What the merchant platform knows the refund by, written down before the
    # call: a request that never came back would otherwise leave nothing to look
    # the refund up by.
    it 'writes the refund number to metadata before the call' do
      allow(gateway.client).to receive(:post).and_raise(
        SpreeWechatPay::ConnectionError.new('WeChat Pay could not be reached')
      )

      expect { gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund) }
        .to raise_error(SpreeWechatPay::ConnectionError)
      expect(refund.reload.metadata['wechat_pay_out_refund_no']).to be_present
    end

    # WeChat treats `out_refund_no` as an idempotency key: a retry has to present
    # the number the first attempt used, or the money goes back twice. Core
    # destroys the refund row when a credit fails, so the retry rebuilds the
    # count from the same rows and must land on the same number.
    it 'presents the same number when a failed attempt is retried' do
      gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund)
      first_number = refund.reload.metadata['wechat_pay_out_refund_no']

      refund.destroy!
      retried = create(:refund, payment: payment, amount: 5)
      gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: retried)

      expect(first_number).to eq("#{payment.transaction_id}-r1")
      expect(retried.reload.metadata['wechat_pay_out_refund_no']).to eq(first_number)
    end

    it 'counts a genuine second refund of the same payment one higher' do
      gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund)
      another = create(:refund, payment: payment, amount: 2)
      gateway.credit(Spree::Money.new(2, currency: 'CNY'), payment.response_code, originator: another)

      expect(another.reload.metadata['wechat_pay_out_refund_no'])
        .to eq("#{payment.transaction_id}-r2")
    end

    # WeChat settles a refund after accepting it, so its identifiers are kept
    # for an operator to check the refund against the merchant platform.
    it 'records what WeChat said about a refund it accepted' do
      gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund)

      expect(refund.reload.metadata).to include(
        'wechat_pay_refund_id' => 'r1',
        'wechat_pay_refund_status' => 'PROCESSING'
      )
    end

    it 'accepts a refund WeChat settled at once' do
      allow(gateway.client).to receive(:post).and_return('refund_id' => 'r1', 'status' => 'SUCCESS')

      expect(gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund)).to be_success
    end

    # `CLOSED` is a refund that never happened, so it is refused rather than
    # recorded — core destroys the uncredited row and the operator reads why.
    it 'refuses a refund WeChat closed without returning the money' do
      allow(gateway.client).to receive(:post).and_return('refund_id' => 'r1', 'status' => 'CLOSED')

      expect { gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund) }.to raise_error(
        Spree::Core::GatewayError, /Nothing was refunded/
      )
    end

    it 'surfaces a definite rejection in WeChat own words' do
      allow(gateway.client).to receive(:post).and_raise(
        SpreeWechatPay::ApiError.new('余额不足', code: 'NOT_ENOUGH')
      )

      expect { gateway.credit(Spree::Money.new(5, currency: 'CNY'), payment.response_code, originator: refund) }.to raise_error(
        Spree::Core::GatewayError, /余额不足/
      )
    end
  end

  # WeChat takes the money at checkout, so cancel has nothing to void — the only
  # thing it can do with a captured payment is give it back, through the one
  # refund path core owns.
  describe '#cancel' do
    let(:gateway) { wechat_gateway }
    let(:cart) { wechat_cart }

    let(:payment) do
      session = Spree::PaymentSessions::WechatPay.create!(
        owner: cart, payment_method: gateway, amount: cart.total, currency: 'CNY',
        status: 'pending', external_id: 'R1001-cancel'
      )
      session.settle_payment!(captured: true, metadata: {})
    end

    it 'answers success when there is no completed payment to settle' do
      expect(gateway.cancel('R1001-abcd1234', nil)).to be_success
    end

    it 'leaves captured money alone when the operator asked to keep it' do
      expect(Spree.refund_create_workflow).not_to receive(:call)

      expect(gateway.cancel(payment.response_code, payment, refund: false)).to be_success
    end

    it 'refunds a captured payment through the refund workflow' do
      refund = instance_double(
        Spree::Refund,
        response: Spree::PaymentResponse.new(true, nil, {}, authorization: 'refund-1')
      )
      allow(Spree.refund_create_workflow).to receive(:call).and_return(
        Spree::ServiceModule::Result.new(true, refund, nil)
      )

      expect(gateway.cancel(payment.response_code, payment)).to be_success
      expect(Spree.refund_create_workflow).to have_received(:call).with(
        hash_including(payment: payment, reason: a_kind_of(Spree::RefundReason))
      )
    end
  end

  describe '#void' do
    let(:gateway) { wechat_gateway }

    it 'answers success, because WeChat has no uncaptured authorization to release' do
      expect(gateway.void('R1001-abcd1234')).to be_success
    end
  end

  describe 'sensitive fields' do
    let(:gateway) { wechat_gateway }

    # Public key mode is the helper's default, so encryption uses the configured
    # WeChat Pay public key — the spec's `platform_key_pair` holds its private
    # half, standing in for WeChat.
    it 'encrypts a field only WeChat can read' do
      ciphertext = gateway.encrypt_sensitive_field('张三')

      expect(SpreeWechatPay::SensitiveField.decrypt(ciphertext, key: platform_key_pair)).to eq('张三')
    end

    it 'decrypts a field WeChat encrypted against the merchant certificate' do
      ciphertext = SpreeWechatPay::SensitiveField.encrypt('张三', key: merchant_key_pair.public_key)

      expect(gateway.decrypt_sensitive_field(ciphertext)).to eq('张三')
    end
  end

  # Every v3 answer is verified before it is believed, with one explicit
  # exception: the certificate download, which exists to fetch the very keys
  # verification needs. OAuth is a different host and protocol, not v3.
  #
  #   Verified    transaction create (all five scenes), query, close, refund,
  #               refund query
  #   Unverified  certificate download
  #   Not v3      OAuth access_token, OAuth jscode2session
  describe 'response verification' do
    it 'routes every payment and refund call through a verified client' do
      allow(SpreeWechatPay::Client).to receive(:new).and_call_original

      gateway.send(:transaction_for, 'R1001-abcd1234')
      gateway.send(:refund_for, 're_test-ABCDEF12')

      expect(SpreeWechatPay::Client).to have_received(:new).with(hash_including(:verifier)).twice
    end

    it 'leaves only the certificate download unverified' do
      allow(SpreeWechatPay::Client).to receive(:new).and_call_original

      gateway.certificate_store

      expect(SpreeWechatPay::Client).to have_received(:new).with(hash_excluding(:verifier)).once
    end

    it 'keeps the OAuth exchange out of the v3 client entirely' do
      allow(SpreeWechatPay::Client).to receive(:new)

      expect(gateway.send(:oauth)).to be_a(SpreeWechatPay::Oauth)
      expect(SpreeWechatPay::Client).not_to have_received(:new)
    end
  end
end
