require 'spec_helper'

RSpec.describe SpreeWechatPay::LaunchParameters do
  let(:context) { merchant_context }
  let(:signer) { context.signer }
  let(:prepay_id) { 'wx201410272009395522657a690389285100' }

  def params(scene: 'jsapi', app_id: 'wx_jsapi_appid')
    described_class.new(
      signer: signer, scene: scene, app_id: app_id, prepay_id: prepay_id,
      timestamp: '1554208460', nonce: 'NONCE_STRING'
    ).to_h
  end

  describe 'for JSAPI' do
    it 'hands the storefront a finished parameter set' do
      expect(params.keys).to contain_exactly(
        'appId', 'timeStamp', 'nonceStr', 'package', 'signType', 'paySign'
      )
    end

    it 'wraps the prepay id the way the launch call expects' do
      expect(params['package']).to eq("prepay_id=#{prepay_id}")
    end

    it 'names the signature algorithm' do
      expect(params['signType']).to eq('RSA')
    end

    it 'sends the timestamp as a string' do
      expect(params['timeStamp']).to eq('1554208460')
    end

    # The signature is over `appId\n时间戳\n随机串\nprepay_id=<value>\n`, and it is
    # produced here — a storefront that signed for itself would have to hold the
    # merchant private key, and getting the fourth line wrong makes the payment
    # silently not start.
    it 'signs the four lines the launch call is verified against' do
      expected = "wx_jsapi_appid\n1554208460\nNONCE_STRING\nprepay_id=#{prepay_id}\n"

      expect(
        context.private_key.public_key.verify(
          OpenSSL::Digest.new('SHA256'),
          Base64.strict_decode64(params['paySign']),
          expected
        )
      ).to be true
    end

    it 'generates a nonce of its own when not given one' do
      generated = described_class.new(
        signer: signer, scene: 'jsapi', app_id: 'wx_jsapi_appid', prepay_id: prepay_id
      ).to_h

      expect(generated['nonceStr'].length).to be_between(1, 32)
      expect(generated['timeStamp']).to match(/\A\d+\z/)
    end
  end

  describe 'for the mini program' do
    subject(:mini) { params(scene: 'mini_program', app_id: 'wx_mini_appid') }

    # Not a nicety: repeating `appId` in the launch call is not an error WeChat
    # reports — the payment silently does not start.
    it 'omits the application identifier from the launch call' do
      expect(mini).not_to have_key('appId')
    end

    it 'carries everything else the launch call needs' do
      expect(mini.keys).to contain_exactly('timeStamp', 'nonceStr', 'package', 'signType', 'paySign')
    end

    # The identifier is still the first line of what gets signed, even though it
    # is not a field on the wire.
    it 'still signs with the mini program identifier' do
      expected = "wx_mini_appid\n1554208460\nNONCE_STRING\nprepay_id=#{prepay_id}\n"

      expect(
        context.private_key.public_key.verify(
          OpenSSL::Digest.new('SHA256'),
          Base64.strict_decode64(mini['paySign']),
          expected
        )
      ).to be true
    end
  end

  # APP's signed string differs in its fourth line, and the field set is the app
  # SDK's `PayReq` rather than the browser bridge's.
  describe 'for APP' do
    subject(:app) { params(scene: 'app', app_id: 'wx_app_appid') }

    it 'hands the app SDK its PayReq field set' do
      expect(app.keys).to contain_exactly(
        'appId', 'partnerId', 'prepayId', 'package', 'nonceStr', 'timeStamp', 'sign'
      )
    end

    it 'names the merchant as the partner' do
      expect(app['partnerId']).to eq(WechatPaySpecHelpers::MERCHANT_ID)
    end

    it 'carries the prepay id bare, not wrapped' do
      expect(app['prepayId']).to eq(prepay_id)
    end

    it 'uses the fixed package value' do
      expect(app['package']).to eq('Sign=WXPay')
    end

    # The fourth line is the bare prepay id — not `prepay_id=<value>` as the
    # browser scenes sign — and getting it wrong makes the payment silently not
    # start.
    it 'signs the bare prepay id' do
      expected = "wx_app_appid\n1554208460\nNONCE_STRING\n#{prepay_id}\n"

      expect(
        context.private_key.public_key.verify(
          OpenSSL::Digest.new('SHA256'),
          Base64.strict_decode64(app['sign']),
          expected
        )
      ).to be true
    end
  end

  # Native and H5 carry a URL, not a signed parameter set, so they have no
  # launch parameters to build.
  it 'refuses a scene whose launch parameters are not implemented' do
    expect { params(scene: 'native') }.to raise_error(ArgumentError, /native/)
  end
end
