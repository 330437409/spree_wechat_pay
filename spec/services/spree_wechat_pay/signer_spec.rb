require 'spec_helper'

RSpec.describe SpreeWechatPay::Signer do
  let(:context) { merchant_context }
  let(:signer) { context.signer }
  let(:public_key) { merchant_key_pair.public_key }

  def verify(signature, message)
    public_key.verify(OpenSSL::Digest.new('SHA256'), Base64.strict_decode64(signature), message)
  end

  describe '#authorization_header' do
    subject(:header) do
      signer.authorization_header(
        method: :post,
        path: '/v3/pay/transactions/jsapi',
        body: '{"appid":"wx_jsapi_appid"}',
        timestamp: 1554208460,
        nonce: 'NONCE_STRING'
      )
    end

    def signature_from(header)
      header[/signature="([^"]+)"/, 1]
    end

    it 'signs the five-line string the specification defines' do
      expected = [
        'POST',
        '/v3/pay/transactions/jsapi',
        '1554208460',
        'NONCE_STRING',
        '{"appid":"wx_jsapi_appid"}',
        ''
      ].join("\n")

      expect(verify(signature_from(header), expected)).to be true
    end

    it 'signs an empty body for a request that carries none' do
      header = signer.authorization_header(
        method: :get, path: '/v3/certificates', timestamp: 1554208460, nonce: 'NONCE_STRING'
      )
      # Five lines, each terminated: the empty body is still a line.
      expected = "GET\n/v3/certificates\n1554208460\nNONCE_STRING\n\n"

      expect(verify(signature_from(header), expected)).to be true
    end

    # The path is inside the signed string, which is why partner mode is a real
    # change and not just a different URL.
    it 'signs the path, so a different path does not verify' do
      other = signer.authorization_header(
        method: :post, path: '/v3/pay/partner/transactions/jsapi',
        body: '{"appid":"wx_jsapi_appid"}', timestamp: 1554208460, nonce: 'NONCE_STRING'
      )

      expect(signature_from(other)).not_to eq(signature_from(header))
    end

    it 'names the merchant certificate serial in the header' do
      expect(header).to include(%(serial_no="#{WechatPaySpecHelpers::MERCHANT_SERIAL}"))
      expect(header).to include(%(mchid="#{WechatPaySpecHelpers::MERCHANT_ID}"))
      expect(header).to start_with('WECHATPAY2-SHA256-RSA2048 ')
    end
  end

  describe '#launch_signature' do
    let(:prepay_id) { 'wx201410272009395522657a690389285100' }
    let(:args) do
      { app_id: 'wx_jsapi_appid', prepay_id: prepay_id, timestamp: '1554208460', nonce: 'NONCE_STRING' }
    end

    # The fourth line differs per scene, and a wrong one makes WeChat refuse to
    # start the payment without reporting anything useful.
    it 'signs the prefixed identifier for JSAPI' do
      signature = signer.launch_signature(**args, scene: 'jsapi')
      expected = "wx_jsapi_appid\n1554208460\nNONCE_STRING\nprepay_id=#{prepay_id}\n"

      expect(verify(signature, expected)).to be true
    end

    it 'signs the prefixed identifier for the mini program, with its own app id' do
      signature = signer.launch_signature(
        **args.merge(app_id: 'wx_mini_appid'), scene: 'mini_program'
      )
      expected = "wx_mini_appid\n1554208460\nNONCE_STRING\nprepay_id=#{prepay_id}\n"

      expect(verify(signature, expected)).to be true
    end

    it 'signs the bare identifier for APP' do
      signature = signer.launch_signature(**args.merge(app_id: 'wx_app_appid'), scene: 'app')
      expected = "wx_app_appid\n1554208460\nNONCE_STRING\n#{prepay_id}\n"

      expect(verify(signature, expected)).to be true
    end

    it 'produces a different signature for APP than for JSAPI on the same order' do
      jsapi = signer.launch_signature(**args, scene: 'jsapi')
      app = signer.launch_signature(**args, scene: 'app')

      expect(jsapi).not_to eq(app)
    end
  end
end
