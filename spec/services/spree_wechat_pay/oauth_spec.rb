require 'spec_helper'

RSpec.describe SpreeWechatPay::Oauth do
  let(:context) { merchant_context }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) do
    Faraday.new(url: described_class::BASE_URL) { |faraday| faraday.adapter :test, stubs }
  end
  let(:oauth) { described_class.new(context: context, connection: connection) }

  describe '#openid_for' do
    it 'exchanges an authorization code for the payer identity' do
      stubs.get('/sns/oauth2/access_token') do |env|
        expect(env.params).to include(
          'appid' => 'wx_jsapi_appid',
          'secret' => WechatPaySpecHelpers::JSAPI_APP_SECRET,
          'code' => 'CODE123',
          'grant_type' => 'authorization_code'
        )
        [200, { 'Content-Type' => 'application/json' },
         '{"access_token":"t","expires_in":7200,"openid":"oUpF8u"}']
      end

      expect(oauth.openid_for(scene: 'jsapi', code: 'CODE123')).to eq('oUpF8u')
    end

    # A mini program exchanges a different kind of code, at a different path,
    # under a different parameter name — getting any of those wrong is refused
    # by WeChat with a bare parameter complaint.
    it 'exchanges a mini program login code at the mini program endpoint' do
      stubs.get('/sns/jscode2session') do |env|
        expect(env.params).to include(
          'appid' => 'wx_mini_appid',
          'secret' => WechatPaySpecHelpers::MINI_PROGRAM_APP_SECRET,
          'js_code' => 'JSCODE123',
          'grant_type' => 'authorization_code'
        )
        [200, { 'Content-Type' => 'application/json' },
         '{"openid":"oUpF8u","session_key":"SESSIONKEY"}']
      end

      expect(oauth.openid_for(scene: 'mini_program', code: 'JSCODE123')).to eq('oUpF8u')
    end

    it 'refuses a scene it has no exchange for' do
      expect { oauth.openid_for(scene: 'native', code: 'x') }.to raise_error(ArgumentError)
    end

    # The documentation does not say what HTTP status an error carries, so the
    # body is what decides. Reading the status would report "no openid" for
    # every refusal, which names nothing.
    it 'reports a spent code as the customer needing to start over' do
      stubs.get('/sns/oauth2/access_token') do
        [200, {}, '{"errcode":40163,"errmsg":"code been used"}']
      end

      expect { oauth.openid_for(scene: 'jsapi', code: 'USED') }.to raise_error(
        SpreeWechatPay::ApiError, /no longer usable.*start the payment again/m
      )
    end

    it 'reports an expired code the same way, because the fix is the same' do
      stubs.get('/sns/oauth2/access_token') do
        [200, {}, '{"errcode":42003,"errmsg":"code expired"}']
      end

      expect { oauth.openid_for(scene: 'jsapi', code: 'OLD') }.to raise_error(
        SpreeWechatPay::ApiError, /start the payment again/
      )
    end

    it 'reports rejected credentials as a configuration problem' do
      stubs.get('/sns/oauth2/access_token') do
        [200, {}, '{"errcode":40125,"errmsg":"invalid appsecret"}']
      end

      expect { oauth.openid_for(scene: 'jsapi', code: 'x') }.to raise_error(
        SpreeWechatPay::ApiError, /AppID and AppSecret belong to the same account/
      )
    end

    it 'carries WeChat error code' do
      stubs.get('/sns/oauth2/access_token') { [200, {}, '{"errcode":40029,"errmsg":"invalid code"}'] }

      expect { oauth.openid_for(scene: 'jsapi', code: 'x') }.to raise_error(
        SpreeWechatPay::ApiError
      ) { |error| expect(error.code).to eq('40029') }
    end

    it 'still reads the body when the status is not a success' do
      stubs.get('/sns/oauth2/access_token') do
        [500, {}, '{"errcode":40029,"errmsg":"invalid code"}']
      end

      expect { oauth.openid_for(scene: 'jsapi', code: 'x') }.to raise_error(SpreeWechatPay::ApiError)
    end

    it 'refuses a success response with no openid rather than returning nothing' do
      stubs.get('/sns/oauth2/access_token') { [200, {}, '{"access_token":"t"}'] }

      expect { oauth.openid_for(scene: 'jsapi', code: 'x') }.to raise_error(
        SpreeWechatPay::ApiError, /did not return an openid/
      )
    end

    it 'reports an unreachable WeChat as unknown rather than as a refusal' do
      stubs.get('/sns/oauth2/access_token') { raise Faraday::TimeoutError }

      expect { oauth.openid_for(scene: 'jsapi', code: 'x') }.to raise_error(
        SpreeWechatPay::ConnectionError
      )
    end
  end
end
