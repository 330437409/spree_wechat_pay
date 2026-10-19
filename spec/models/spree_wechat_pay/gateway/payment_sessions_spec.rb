require 'spec_helper'

RSpec.describe SpreeWechatPay::Gateway::PaymentSessions do
  let(:gateway) { wechat_gateway }
  let(:cart) { wechat_cart }

  def stub_client(path, response)
    client = instance_double(SpreeWechatPay::Client)
    if response.is_a?(StandardError)
      allow(client).to receive(:post).with(path, anything).and_raise(response)
      allow(client).to receive(:get).with(path, any_args).and_raise(response)
    else
      allow(client).to receive(:post).with(path, anything).and_return(response)
      allow(client).to receive(:get).with(path, any_args).and_return(response)
    end
    allow(gateway).to receive(:client).and_return(client)
    client
  end

  # What WeChat says the transaction's `trade_state` is when the gateway reads
  # it before closing or replacing it.
  def stub_transaction_query(number, trade_state)
    allow(gateway.client).to receive(:get).with(
      "/v3/pay/transactions/out-trade-no/#{number}?mchid=#{WechatPaySpecHelpers::MERCHANT_ID}"
    ).and_return('trade_state' => trade_state)
  end

  def stub_transaction_query_error(number, error)
    allow(gateway.client).to receive(:get).with(
      "/v3/pay/transactions/out-trade-no/#{number}?mchid=#{WechatPaySpecHelpers::MERCHANT_ID}"
    ).and_raise(error)
  end

  describe '#create_payment_session' do
    let(:code_url) { 'weixin://wxpay/bizpayurl/up?pr=NwY5Mz9&groupid=00' }

    before { stub_client('/v3/pay/transactions/native', { 'code_url' => code_url }) }

    it 'creates a session addressed by our merchant order number' do
      session = gateway.create_payment_session(order: cart)

      expect(session).to be_persisted
      expect(session.external_id).to eq(session.merchant_order_number)
      expect(SpreeWechatPay::MerchantOrderNumber.valid?(session.external_id)).to be true
    end

    it 'hands the storefront the QR link to render' do
      session = gateway.create_payment_session(order: cart, external_data: { scene: 'native' })

      expect(session.code_url).to eq(code_url)
      expect(session.scene).to eq('native')
    end

    # Two clocks, and they are not the same: the transaction stays payable for
    # days while the QR link it came with is good for two hours.
    it 'separates the token lifetime from the transaction lifetime' do
      session = gateway.create_payment_session(order: cart)

      expect(session.payload_expires_at).to be_within(1.minute).of(2.hours.from_now)
      expect(session.expires_at).to be_within(1.minute).of(7.days.from_now)
      expect(session.payload_expired?).to be false
    end

    # Sent explicitly rather than left to WeChat's own seven-day default, so the
    # window the session records and the window WeChat enforces cannot drift
    # apart.
    it 'tells WeChat when the transaction stops being payable' do
      sent = nil
      allow(gateway.client).to receive(:post).with('/v3/pay/transactions/native', anything) do |_path, body|
        sent = body
        { 'code_url' => code_url }
      end

      session = gateway.create_payment_session(order: cart)

      expect(Time.iso8601(sent['time_expire'])).to be_within(1.second).of(session.expires_at)
    end

    it 'sends the amount in fen, which is what WeChat counts in' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native',
        hash_including('amount' => { 'total' => Spree::Money.new(cart.total, currency: 'CNY').cents,
                                     'currency' => 'CNY' })
      ).and_return('code_url' => code_url)

      gateway.create_payment_session(order: cart)
    end

    it 'sends a description, which WeChat requires and shows the customer' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', hash_including('description' => satisfy(&:present?))
      ).and_return('code_url' => code_url)

      gateway.create_payment_session(order: cart)
    end

    # Native carries no payer identity, but WeChat still wants an identifier
    # bound to the merchant number.
    it 'sends the bound application identifier' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native',
        hash_including('appid' => WechatPaySpecHelpers::BOUND_APP_ID)
      ).and_return('code_url' => code_url)

      gateway.create_payment_session(order: cart)
    end

    it 'omits the scene object rather than sending an incomplete one' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', hash_excluding('scene_info')
      ).and_return('code_url' => code_url)

      gateway.create_payment_session(order: cart)
    end

    it 'sends the customer IP when the storefront forwards it' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native',
        hash_including('scene_info' => { 'payer_client_ip' => '203.0.113.7' })
      ).and_return('code_url' => code_url)

      gateway.create_payment_session(order: cart, external_data: { payer_client_ip: '203.0.113.7' })
    end

    it 'points WeChat at this store\'s own callback URL' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', hash_including('notify_url' => gateway.webhook_url)
      ).and_return('code_url' => code_url)

      gateway.create_payment_session(order: cart)
    end

    it 'refuses a zero amount rather than asking WeChat to reject it' do
      expect { gateway.create_payment_session(order: cart, amount: 0) }.to raise_error(
        Spree::Core::GatewayError
      )
    end

    # A scene the merchant never switched on is refused, not substituted: the
    # storefront asked for it because it can drive that one.
    it 'refuses a scene that is not enabled' do
      expect { gateway.create_payment_session(order: cart, external_data: { scene: 'jsapi' }) }.to raise_error(
        Spree::Core::GatewayError, /jsapi/
      )
    end

    it 'needs to be told which scene when more than one is enabled' do
      gateway.preferred_enabled_scenes = %w[native jsapi]
      gateway.save!

      expect { gateway.create_payment_session(order: cart) }.to raise_error(
        Spree::Core::GatewayError, /scene/
      )
    end

    it 'refuses to work at all with no scene enabled' do
      gateway.preferred_enabled_scenes = []
      gateway.save!

      expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError)
    end
  end

  # JSAPI is the same transaction as Native with a payer added: the appid is the
  # official account's, and WeChat will not accept the order without the payer's
  # openid.
  describe 'the JSAPI scene' do
    let(:gateway) { wechat_gateway(enabled_scenes: %w[jsapi]) }
    let(:oauth) { instance_double(SpreeWechatPay::Oauth) }
    let(:prepay_id) { 'wx281410272009395522657a690389285100' }

    before do
      allow(gateway).to receive(:oauth).and_return(oauth)
      allow(oauth).to receive(:openid_for).and_return('oUpF8uMuAJO_M2pxb1Q9zNjWeS6o')
      stub_client('/v3/pay/transactions/jsapi', { 'prepay_id' => prepay_id })
    end

    it 'exchanges the authorization code rather than trusting a supplied openid' do
      expect(oauth).to receive(:openid_for).with(scene: 'jsapi', code: 'CODE123')

      gateway.create_payment_session(order: cart, external_data: { scene: 'jsapi', code: 'CODE123' })
    end

    it 'names the payer on the order' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/jsapi',
        hash_including('payer' => { 'openid' => 'oUpF8uMuAJO_M2pxb1Q9zNjWeS6o' })
      ).and_return('prepay_id' => prepay_id)

      gateway.create_payment_session(order: cart, external_data: { scene: 'jsapi', code: 'CODE123' })
    end

    it 'uses the official account identifier, not the bound one' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/jsapi', hash_including('appid' => 'wx_jsapi_appid')
      ).and_return('prepay_id' => prepay_id)

      gateway.create_payment_session(order: cart, external_data: { scene: 'jsapi', code: 'CODE123' })
    end

    # The storefront receives a finished parameter set: it never signs, and it
    # never holds the merchant private key.
    it 'hands the storefront signed launch parameters' do
      session = gateway.create_payment_session(
        order: cart, external_data: { scene: 'jsapi', code: 'CODE123' }
      )

      expect(session.external_data['launch_params']).to include(
        'appId' => 'wx_jsapi_appid',
        'package' => "prepay_id=#{prepay_id}",
        'signType' => 'RSA'
      )
      expect(session.external_data['launch_params']['paySign']).to be_present
    end

    # Without a code there is no identity, and WeChat's own complaint about a
    # missing payer is a bare parameter error.
    it 'refuses a session with no authorization code' do
      expect { gateway.create_payment_session(order: cart, external_data: { scene: 'jsapi' }) }
        .to raise_error(Spree::Core::GatewayError, /authorization code/)
    end
  end

  # A scene that is configured but not built must say so, rather than failing
  # somewhere further in where the cause is unrecognisable.
  # The mini program is the same pipeline as JSAPI against the same endpoint;
  # only the identifier and the launch contract differ.
  describe 'the mini program scene' do
    let(:gateway) { wechat_gateway(enabled_scenes: %w[mini_program]) }
    let(:oauth) { instance_double(SpreeWechatPay::Oauth) }
    let(:prepay_id) { 'wx281410272009395522657a690389285100' }

    before do
      allow(gateway).to receive(:oauth).and_return(oauth)
      allow(oauth).to receive(:openid_for).and_return('oUpF8uMuAJO_M2pxb1Q9zNjWeS6o')
      stub_client('/v3/pay/transactions/jsapi', { 'prepay_id' => prepay_id })
    end

    it 'places the order on the shared JSAPI endpoint' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/jsapi', hash_including('appid' => 'wx_mini_appid')
      ).and_return('prepay_id' => prepay_id)

      gateway.create_payment_session(
        order: cart, external_data: { scene: 'mini_program', code: 'JSCODE123' }
      )
    end

    it 'names the payer, as the other identity scene does' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/jsapi',
        hash_including('payer' => { 'openid' => 'oUpF8uMuAJO_M2pxb1Q9zNjWeS6o' })
      ).and_return('prepay_id' => prepay_id)

      gateway.create_payment_session(
        order: cart, external_data: { scene: 'mini_program', code: 'JSCODE123' }
      )
    end

    # Where the two part company: the launch call carries no application
    # identifier, and repeating it does not produce an error — the payment just
    # never starts.
    it 'hands back launch parameters with no application identifier' do
      session = gateway.create_payment_session(
        order: cart, external_data: { scene: 'mini_program', code: 'JSCODE123' }
      )

      expect(session.external_data['launch_params']).not_to have_key('appId')
      expect(session.external_data['launch_params']['package']).to eq("prepay_id=#{prepay_id}")
    end
  end

  # H5 is the same transaction with a mandatory scene object and a redirect URL
  # that lives for five minutes rather than two hours.
  describe 'the H5 scene' do
    let(:gateway) { wechat_gateway(enabled_scenes: %w[h5]) }
    let(:h5_url) { 'https://wx.tenpay.com/cgi-bin/mmpayweb-bin/checkmweb?prepay_id=wx123&package=123' }

    before { stub_client('/v3/pay/transactions/h5', { 'h5_url' => h5_url }) }

    it 'uses the bound application identifier' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/h5', hash_including('appid' => WechatPaySpecHelpers::BOUND_APP_ID)
      ).and_return('h5_url' => h5_url)

      gateway.create_payment_session(
        order: cart, external_data: { scene: 'h5', h5_type: 'Wap', payer_client_ip: '203.0.113.7' }
      )
    end

    # Where H5 differs from every other scene: `scene_info.h5_info.type` is
    # required, and `payer_client_ip` is required whenever scene_info is sent.
    it 'sends the mandatory scene object' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/h5',
        hash_including('scene_info' => {
          'h5_info' => { 'type' => 'Wap' }, 'payer_client_ip' => '203.0.113.7'
        })
      ).and_return('h5_url' => h5_url)

      gateway.create_payment_session(
        order: cart, external_data: { scene: 'h5', h5_type: 'Wap', payer_client_ip: '203.0.113.7' }
      )
    end

    # WeChat refuses a repeat of an `out_trade_no` whose parameters differ, and
    # the customer's IP is the one parameter that moves on its own — so a
    # re-issue sends back the scene object the transaction was placed with.
    it 're-issues with the scene object the transaction was placed with' do
      session = gateway.create_payment_session(
        order: cart, external_data: { scene: 'h5', h5_type: 'Wap', payer_client_ip: '203.0.113.7' }
      )
      session.update!(external_data: session.external_data.merge(
        'payload_expires_at' => 1.minute.ago.iso8601
      ))
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/h5',
        hash_including('scene_info' => {
          'h5_info' => { 'type' => 'Wap' }, 'payer_client_ip' => '203.0.113.7'
        })
      ).and_return('h5_url' => h5_url)

      # The customer has moved since; the transaction they are paying has not.
      gateway.update_payment_session(
        payment_session: session.reload, external_data: { payer_client_ip: '198.51.100.9' }
      )
    end

    it 'refuses to place an H5 order without a device type' do
      expect {
        gateway.create_payment_session(
          order: cart, external_data: { scene: 'h5', payer_client_ip: '203.0.113.7' }
        )
      }.to raise_error(Spree::Core::GatewayError, /device type/)
    end

    it 'refuses to place an H5 order without the customer IP' do
      expect {
        gateway.create_payment_session(order: cart, external_data: { scene: 'h5', h5_type: 'Wap' })
      }.to raise_error(Spree::Core::GatewayError, /IP address/)
    end

    it 'hands the storefront the H5 link, good for five minutes' do
      session = gateway.create_payment_session(
        order: cart, external_data: { scene: 'h5', h5_type: 'Wap', payer_client_ip: '203.0.113.7' }
      )

      expect(session.h5_url).to eq(h5_url)
      expect(session.payload_expires_at).to be_within(1.minute).of(5.minutes.from_now)
    end

    # The URL is passed through untouched except for the return address WeChat
    # redirects to after payment, which is appended URL-encoded.
    it 'extends the link with the URL-encoded return address' do
      session = gateway.create_payment_session(
        order: cart,
        external_data: {
          scene: 'h5', h5_type: 'Wap', payer_client_ip: '203.0.113.7',
          redirect_url: 'https://shop.example/return?order=1'
        }
      )

      expect(session.h5_url).to start_with(h5_url)
      expect(session.h5_url).to end_with("redirect_url=#{CGI.escape('https://shop.example/return?order=1')}")
    end
  end

  # APP is the same transaction as Native — no payer, no scene object — but the
  # response is a prepay id and the launch contract is the app SDK's PayReq.
  describe 'the APP scene' do
    let(:gateway) { wechat_gateway(enabled_scenes: %w[app]) }
    let(:prepay_id) { 'wx281410272009395522657a690389285100' }

    before { stub_client('/v3/pay/transactions/app', { 'prepay_id' => prepay_id }) }

    it 'uses the open-platform application identifier' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/app', hash_including('appid' => 'wx_app_appid')
      ).and_return('prepay_id' => prepay_id)

      gateway.create_payment_session(order: cart, external_data: { scene: 'app' })
    end

    it 'names no payer on the order' do
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/app', hash_excluding('payer')
      ).and_return('prepay_id' => prepay_id)

      gateway.create_payment_session(order: cart, external_data: { scene: 'app' })
    end

    it 'hands the storefront the APP launch parameter set' do
      session = gateway.create_payment_session(order: cart, external_data: { scene: 'app' })

      expect(session.external_data['launch_params']).to include(
        'appId' => 'wx_app_appid',
        'partnerId' => WechatPaySpecHelpers::MERCHANT_ID,
        'prepayId' => prepay_id,
        'package' => 'Sign=WXPay'
      )
      expect(session.external_data['launch_params']['sign']).to be_present
    end
  end

  # A scene in the vocabulary but not in IMPLEMENTED_SCENES must say so, rather
  # than failing somewhere further in where the cause is unrecognisable. Every
  # scene is implemented today, so the guard is exercised by narrowing the list.
  describe 'a scene that is not implemented yet' do
    before do
      stub_const(
        'SpreeWechatPay::Gateway::PaymentSessions::IMPLEMENTED_SCENES',
        %w[native jsapi mini_program]
      )
    end

    it 'refuses plainly' do
      gateway = wechat_gateway(enabled_scenes: %w[h5])

      expect { gateway.create_payment_session(order: cart) }.to raise_error(
        Spree::Core::GatewayError, /not available in this version/
      )
    end
  end

  describe '#update_payment_session' do
    let(:code_url) { 'weixin://wxpay/bizpayurl/up?pr=old&groupid=00' }
    let(:new_code_url) { 'weixin://wxpay/bizpayurl/up?pr=new&groupid=00' }
    let(:session) { gateway.create_payment_session(order: cart) }

    before { stub_client('/v3/pay/transactions/native', { 'code_url' => code_url }) }

    # Asking twice must not open a second transaction.
    it 'does nothing when the amount is unchanged and the token is still live' do
      session = gateway.create_payment_session(order: cart)
      expect(gateway.client).not_to receive(:post)

      gateway.update_payment_session(payment_session: session)
    end

    it 're-issues under the same number when only the token has lapsed' do
      session = gateway.create_payment_session(order: cart)
      session.update!(external_data: session.external_data.merge(
        'payload_expires_at' => 1.minute.ago.iso8601
      ))
      expect(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', hash_including('out_trade_no' => session.merchant_order_number)
      ).and_return('code_url' => new_code_url)

      gateway.update_payment_session(payment_session: session.reload)

      expect(session.reload.code_url).to eq(new_code_url)
      expect(session.payload_expired?).to be false
    end

    # WeChat cannot change the amount of an open transaction, so the old one is
    # closed and a new one takes its place under a fresh number.
    it 'replaces the transaction when the amount moves' do
      session = gateway.create_payment_session(order: cart)
      old_number = session.merchant_order_number
      stub_transaction_query(old_number, 'NOTPAY')
      allow(gateway.client).to receive(:post).with(
        "/v3/pay/transactions/out-trade-no/#{old_number}/close", anything
      ).and_return({})
      allow(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', anything
      ).and_return('code_url' => new_code_url)

      gateway.update_payment_session(payment_session: session, amount: cart.total + 5)

      expect(session.reload.merchant_order_number).not_to eq(old_number)
      expect(SpreeWechatPay::MerchantOrderNumber.valid?(session.merchant_order_number)).to be true
      expect(session.amount).to eq(cart.total + 5)
    end

    # Replacing a paid transaction would re-point the session away from the
    # number the money is arriving against, and the customer's payment would
    # find no session to settle. Refusing leaves the session where it is.
    it 'refuses to replace a transaction the customer has already paid' do
      session = gateway.create_payment_session(order: cart)
      old_number = session.merchant_order_number
      stub_transaction_query(old_number, 'SUCCESS')

      expect {
        gateway.update_payment_session(payment_session: session, amount: cart.total + 5)
      }.to raise_error(Spree::Core::GatewayError, /already been paid/)

      expect(session.reload.merchant_order_number).to eq(old_number)
      expect(session.amount).not_to eq(cart.total + 5)
    end

    # A number that was never created has nothing to close, so the replacement
    # goes ahead.
    it 'replaces anyway when the old transaction was never created' do
      session = gateway.create_payment_session(order: cart)
      stub_transaction_query_error(
        session.merchant_order_number,
        SpreeWechatPay::ApiError.new('订单不存在', code: 'ORDER_NOT_EXIST', status: 404)
      )
      allow(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', anything
      ).and_return('code_url' => new_code_url)

      gateway.update_payment_session(payment_session: session, amount: cart.total + 5)

      expect(session.reload.code_url).to eq(new_code_url)
    end

    # WeChat has already closed it, so there is nothing left to close and asking
    # again is refused.
    it 'replaces without closing a transaction WeChat has already closed' do
      session = gateway.create_payment_session(order: cart)
      stub_transaction_query(session.merchant_order_number, 'CLOSED')
      allow(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', anything
      ).and_return('code_url' => new_code_url)

      gateway.update_payment_session(payment_session: session, amount: cart.total + 5)

      expect(gateway.client).not_to have_received(:post).with(%r{/close$}, anything)
      expect(session.reload.code_url).to eq(new_code_url)
    end
  end

  # A WeChat authorization code is single use, so refreshing a session for a
  # scene that carries a payer identity must exchange it once and hand the
  # result to both the transaction and the session. Exchanging it twice failed
  # the refresh after the new transaction had already been created.
  describe '#update_payment_session with a payer identity' do
    let(:gateway) { wechat_gateway(enabled_scenes: %w[jsapi]) }
    let(:oauth) { instance_double(SpreeWechatPay::Oauth) }
    let(:prepay_id) { 'wx281410272009395522657a690389285100' }

    before do
      allow(gateway).to receive(:oauth).and_return(oauth)
      allow(oauth).to receive(:openid_for).and_return('oUpF8uMuAJO_M2pxb1Q9zNjWeS6o')
      stub_client('/v3/pay/transactions/jsapi', { 'prepay_id' => prepay_id })
    end

    def lapsed(session)
      session.update!(external_data: session.external_data.merge(
        'payload_expires_at' => 1.minute.ago.iso8601
      ))
      session.reload
    end

    it 'exchanges a supplied code exactly once across the refresh' do
      session = gateway.create_payment_session(
        order: cart, external_data: { scene: 'jsapi', code: 'CODE123' }
      )

      expect(oauth).to receive(:openid_for).once.and_return('oUpF8uMuAJO_M2pxb1Q9zNjWeS6o')
      gateway.update_payment_session(payment_session: lapsed(session), external_data: { code: 'CODE456' })

      expect(session.reload.payload_expired?).to be false
    end

    # Renewing a lapsed launch token for a payer who never left needs no new
    # code — the session already knows who is paying.
    it 'falls back to the openid the session already holds when no code arrives' do
      session = gateway.create_payment_session(
        order: cart, external_data: { scene: 'jsapi', code: 'CODE123' }
      )

      expect(oauth).not_to receive(:openid_for)
      gateway.update_payment_session(payment_session: lapsed(session))

      expect(session.reload.payload_expired?).to be false
    end
  end

  # Core's convention: the callback returns whether the session was canceled,
  # and a provider refusal is a `GatewayError` so the caller leaves the session
  # alone. Anything else — an unreachable WeChat — is raised as itself, so the
  # caller asks again rather than recording a payable session as canceled.
  describe '#cancel_payment_session' do
    let(:code_url) { 'weixin://wxpay/bizpayurl/up?pr=NwY5Mz9&groupid=00' }
    let(:session) { gateway.create_payment_session(order: cart) }

    before { stub_client('/v3/pay/transactions/native', { 'code_url' => code_url }) }

    it 'closes the transaction and cancels the session' do
      stub_transaction_query(session.merchant_order_number, 'NOTPAY')
      allow(gateway.client).to receive(:post).with(
        "/v3/pay/transactions/out-trade-no/#{session.merchant_order_number}/close", anything
      ).and_return({})

      expect(gateway.cancel_payment_session(payment_session: session)).to be true
      expect(session.reload.status).to eq('canceled')
    end

    it 'refuses when the customer has already paid' do
      stub_transaction_query(session.merchant_order_number, 'SUCCESS')

      expect { gateway.cancel_payment_session(payment_session: session) }
        .to raise_error(Spree::Core::GatewayError, /already been paid/)

      expect(session.reload.status).to eq('pending')
    end

    it 'cancels a session whose transaction was never created' do
      stub_transaction_query_error(
        session.merchant_order_number,
        SpreeWechatPay::ApiError.new('订单不存在', code: 'ORDER_NOT_EXIST', status: 404)
      )

      expect(gateway.cancel_payment_session(payment_session: session)).to be true
      expect(session.reload.status).to eq('canceled')
    end

    it 'cancels when the close is refused because WeChat had already closed it' do
      stub_transaction_query(session.merchant_order_number, 'NOTPAY')
      allow(gateway.client).to receive(:post).with(
        "/v3/pay/transactions/out-trade-no/#{session.merchant_order_number}/close", anything
      ).and_raise(SpreeWechatPay::ApiError.new('订单已关闭', code: 'ORDERCLOSED'))

      expect(gateway.cancel_payment_session(payment_session: session)).to be true
      expect(session.reload.status).to eq('canceled')
    end

    it 'raises as itself when WeChat cannot be reached' do
      stub_transaction_query_error(
        session.merchant_order_number,
        SpreeWechatPay::ConnectionError.new('WeChat Pay could not be reached')
      )

      expect { gateway.cancel_payment_session(payment_session: session) }
        .to raise_error(SpreeWechatPay::ConnectionError)
      expect(session.reload.status).to eq('pending')
    end
  end

  # A cart holds at most one open WeChat transaction at a time: a QR code left
  # open from an earlier attempt is still payable, and paying it would take
  # money for a cart that has moved on.
  describe '#create_payment_session with a session already open' do
    let(:code_url) { 'weixin://wxpay/bizpayurl/up?pr=NwY5Mz9&groupid=00' }
    let(:new_code_url) { 'weixin://wxpay/bizpayurl/up?pr=new&groupid=00' }

    before { stub_client('/v3/pay/transactions/native', { 'code_url' => code_url }) }

    it 'closes what the cart already has open before opening another' do
      first = gateway.create_payment_session(order: cart)
      stub_transaction_query(first.merchant_order_number, 'NOTPAY')
      allow(gateway.client).to receive(:post).with(
        "/v3/pay/transactions/out-trade-no/#{first.merchant_order_number}/close", anything
      ).and_return({})
      allow(gateway.client).to receive(:post).with(
        '/v3/pay/transactions/native', anything
      ).and_return('code_url' => new_code_url)

      second = gateway.create_payment_session(order: cart)

      expect(first.reload.status).to eq('canceled')
      expect(second.merchant_order_number).not_to eq(first.merchant_order_number)
    end

    it 'refuses a second session when the cart has already paid' do
      first = gateway.create_payment_session(order: cart)
      stub_transaction_query(first.merchant_order_number, 'SUCCESS')

      expect { gateway.create_payment_session(order: cart) }
        .to raise_error(Spree::Core::GatewayError, /already has a WeChat Pay transaction/)
    end

    # Checkout speaks GatewayError; the unused-session job retries these
    # unwrapped, which is why the wrapping happens here rather than in
    # cancel_payment_session.
    it 'reports an unreachable WeChat as a gateway error' do
      first = gateway.create_payment_session(order: cart)
      stub_transaction_query_error(
        first.merchant_order_number,
        SpreeWechatPay::ConnectionError.new('WeChat Pay could not be reached')
      )

      expect { gateway.create_payment_session(order: cart) }
        .to raise_error(Spree::Core::GatewayError, /could not be reached/)
    end
  end

  describe '#complete_payment_session' do
    let(:session) { gateway.create_payment_session(order: cart) }

    before { stub_client('/v3/pay/transactions/native', { 'code_url' => 'weixin://a' }) }

    def stub_query(response)
      allow(gateway.client).to receive(:get).with(%r{out-trade-no}, any_args).and_return(response)
    end

    it 'settles on what WeChat reports, not on what the storefront claims' do
      session = gateway.create_payment_session(order: cart)
      stub_query(
        'trade_state' => 'SUCCESS', 'transaction_id' => '4200001234',
        'out_trade_no' => session.merchant_order_number, 'payer' => { 'openid' => 'oUpF8u' }
      )

      gateway.complete_payment_session(payment_session: session)

      expect(session.reload).to be_completed
      expect(session.transaction_id).to eq('4200001234')
    end

    it 'records WeChat own identifiers on the payment' do
      session = gateway.create_payment_session(order: cart)
      stub_query(
        'trade_state' => 'SUCCESS', 'transaction_id' => '4200001234',
        'out_trade_no' => session.merchant_order_number, 'payer' => { 'openid' => 'oUpF8u' }
      )

      gateway.complete_payment_session(payment_session: session)

      payment = session.reload.payment
      expect(payment).to be_present
      expect(payment.metadata['wechat_pay_transaction_id']).to eq('4200001234')
      expect(payment.metadata['wechat_pay_openid']).to eq('oUpF8u')
    end

    # WeChat's own instruction: close before declaring failure, because an
    # unpaid transaction can still be paid.
    it 'closes before failing an unpaid transaction' do
      session = gateway.create_payment_session(order: cart)
      stub_query('trade_state' => 'NOTPAY')
      expect(gateway.client).to receive(:post).with(
        "/v3/pay/transactions/out-trade-no/#{session.merchant_order_number}/close", anything
      ).and_return({})

      gateway.complete_payment_session(payment_session: session)

      expect(session.reload).to be_failed
    end

    # The race resolving in the customer's favour: the close is refused because
    # the money arrived between the query and the close, so we settle instead.
    it 'settles when the close is refused because the customer just paid' do
      session = gateway.create_payment_session(order: cart)
      call = 0
      allow(gateway.client).to receive(:get).with(%r{out-trade-no}, any_args) do
        call += 1
        if call == 1
          { 'trade_state' => 'NOTPAY' }
        else
          { 'trade_state' => 'SUCCESS', 'transaction_id' => '4200001234',
            'out_trade_no' => session.merchant_order_number }
        end
      end
      allow(gateway.client).to receive(:post).with(%r{/close$}, anything).and_raise(
        SpreeWechatPay::ApiError.new('订单已支付', code: 'ORDER_PAID', status: 400)
      )

      gateway.complete_payment_session(payment_session: session)

      expect(session.reload).to be_completed
    end

    it 'cancels a session whose transaction WeChat already closed' do
      session = gateway.create_payment_session(order: cart)
      stub_query('trade_state' => 'CLOSED')

      gateway.complete_payment_session(payment_session: session)

      expect(session.reload).to be_canceled
    end

    # The customer is in WeChat's payment sheet: the money is on its way. The
    # transaction is not closed at all — closing it would abort the payment being
    # made through it, and WeChat refuses the close anyway — so the confirm is
    # answered with the session still pending, which core's completion accepts,
    # rather than as an error the storefront cannot read.
    it 'leaves the session alone while the customer is still paying' do
      session = gateway.create_payment_session(order: cart)
      stub_query('trade_state' => 'USERPAYING')
      expect(gateway.client).not_to receive(:post).with(%r{/close$}, anything)

      gateway.complete_payment_session(payment_session: session)

      expect(session.reload).to be_pending
    end
  end
end
