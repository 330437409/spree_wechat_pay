require 'spec_helper'

# The Native flow end to end, up to the seam the gateway owns.
#
# A real notification — really signed, really encrypted — arrives, and a
# completed payment is what comes out. The settlement below is core's own
# `PaymentSession#settle_payment!`, the same call `Payments::HandleWebhook` makes
# inside the owner lock.
#
# Order completion is deliberately not asserted here. It belongs to
# `Carts::Complete`, which core tests, and it runs in the same transaction as the
# settlement — so driving it from this gem's specs would mean reproducing a full
# completable checkout, and a cart that cannot complete would roll the payment
# back and make this spec measure the wrong thing.
RSpec.describe 'Native payment, end to end' do
  let(:gateway) { wechat_gateway }
  let(:cart) { create(:cart, store: wechat_store, currency: 'CNY') }

  let(:fake_client) do
    double('WechatPay client').tap do |client|
      allow(client).to receive(:post).with('/v3/pay/transactions/native', anything)
        .and_return('code_url' => 'weixin://wxpay/bizpayurl/up?pr=E2E')
      allow(client).to receive(:get).with(%r{out-trade-no}, any_args).and_return(queried_transaction)
    end
  end

  # What WeChat says when the session reads the transaction back before
  # settling. Deliberately a different id from the notification's, so a spec
  # that finds this one on the payment proves the read-back happened.
  let(:queried_transaction) do
    {
      'trade_state' => 'SUCCESS',
      'transaction_id' => '4200007777202601011234567890',
      'out_trade_no' => 'queried',
      'payer' => { 'openid' => 'oUpF8uMuAJO_M2pxb1Q9zNjWeS6o' }
    }
  end

  before do
    create(:line_item, cart: cart, order: nil, price: 12.34, quantity: 1)
    cart.recalculate_totals!
    # At the client's own constructor rather than on `gateway.client`: the
    # session a notification resolves is loaded fresh, so its payment method is a
    # different gateway object from the one this spec holds.
    allow(SpreeWechatPay::Client).to receive(:new).and_return(fake_client)
  end

  def notification_for(session, transaction_id: '4200009999202601011234567890', key: platform_key_pair)
    resource = {
      'appid' => WechatPaySpecHelpers::BOUND_APP_ID,
      'mchid' => WechatPaySpecHelpers::MERCHANT_ID,
      'out_trade_no' => session.external_id,
      'transaction_id' => transaction_id,
      'trade_type' => 'NATIVE',
      'trade_state' => 'SUCCESS',
      'trade_state_desc' => '支付成功',
      'payer' => { 'openid' => 'oUpF8uMuAJO_M2pxb1Q9zNjWeS6o' },
      'amount' => { 'total' => 1234, 'payer_total' => 1234, 'currency' => 'CNY' }
    }

    body = JSON.generate(
      'id' => 'EV-E2E-1',
      'resource_type' => 'encrypt-resource',
      'event_type' => 'TRANSACTION.SUCCESS',
      'summary' => '支付成功',
      'resource' => encrypt_like_wechat(JSON.generate(resource), associated_data: 'transaction')
        .merge('original_type' => 'transaction')
    )

    timestamp = Time.current.to_i.to_s
    nonce = 'NONCE123'
    headers = {
      'HTTP_WECHATPAY_TIMESTAMP' => timestamp,
      'HTTP_WECHATPAY_NONCE' => nonce,
      'HTTP_WECHATPAY_SERIAL' => WechatPaySpecHelpers::PUBLIC_KEY_ID,
      'HTTP_WECHATPAY_SIGNATURE' => sign_like_wechat("#{timestamp}\n#{nonce}\n#{body}\n", key: key)
    }

    [body, headers]
  end

  # Everything `Payments::HandleWebhook` does, minus completing the order.
  #
  # The metadata handed to settlement is empty because core's webhook controller
  # does not carry the gateway's parsed metadata through to it; the session reads
  # the same facts back from WeChat in `prepare_for_settlement!` instead.
  def deliver(body, headers)
    parsed = gateway.parse_webhook_event(body, headers)
    session = parsed[:payment_session]

    session.prepare_for_settlement!
    session.settle_payment!(captured: true, metadata: {})
    session.complete if session.can_complete?

    parsed
  end

  def native_session
    gateway.create_payment_session(order: cart, external_data: { scene: 'native' })
  end

  it 'turns a notification into a settled payment' do
    session = native_session
    body, headers = notification_for(session)

    deliver(body, headers)

    session.reload
    expect(session).to be_completed

    payment = session.payment
    expect(payment).to be_present
    expect(payment.amount.to_d).to eq(session.amount.to_d)
    expect(payment).to be_completed
  end

  # Core's webhook controller does not forward the metadata the gateway parsed,
  # so the session reads WeChat's identifiers back before the settlement lock.
  it 'records WeChat own identifiers on the payment' do
    session = native_session
    deliver(*notification_for(session))

    metadata = session.reload.payment.metadata
    expect(metadata['wechat_pay_transaction_id']).to eq('4200007777202601011234567890')
    expect(metadata['wechat_pay_trade_state']).to eq('SUCCESS')
    expect(metadata['wechat_pay_openid']).to eq('oUpF8uMuAJO_M2pxb1Q9zNjWeS6o')
  end

  # Bookkeeping must not hold up recording money that has already moved.
  it 'settles even when WeChat cannot be asked for its identifiers' do
    allow(fake_client).to receive(:get).with(%r{out-trade-no}, any_args).and_raise(
      SpreeWechatPay::ConnectionError.new('WeChat Pay could not be reached')
    )
    session = native_session

    deliver(*notification_for(session))

    expect(session.reload).to be_completed
    expect(session.payment).to be_completed
    expect(session.payment.metadata['wechat_pay_transaction_id']).to be_nil
  end

  # WeChat's refund API accepts a merchant order number, so the identifier core
  # hands to `credit` needs no translation on the refund path.
  it 'keys the payment on the number WeChat refunds by' do
    session = native_session
    deliver(*notification_for(session))

    expect(session.reload.payment.response_code).to eq(session.external_id)
  end

  # WeChat retries fifteen times over roughly 24 hours, so a duplicate is the
  # normal case rather than the exceptional one.
  it 'does not pay twice when the notification is delivered again' do
    session = native_session
    body, headers = notification_for(session)
    deliver(body, headers)

    payments = cart.reload.payments.count
    captured = session.reload.payment.captured_amount

    deliver(body, headers)

    expect(cart.reload.payments.count).to eq(payments)
    expect(session.reload.payment.captured_amount).to eq(captured)
  end

  it 'refuses a notification it cannot verify, and creates nothing' do
    session = native_session
    body, headers = notification_for(session, key: OpenSSL::PKey::RSA.new(2048))

    expect { gateway.parse_webhook_event(body, headers) }.to raise_error(
      Spree::PaymentMethod::WebhookSignatureError
    )
    expect(session.reload.payment).to be_nil
  end
end
