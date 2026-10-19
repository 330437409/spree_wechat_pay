require 'spec_helper'

RSpec.describe SpreeWechatPay::MerchantContext do
  subject(:context) { merchant_context }

  it 'is valid with a full direct credential set' do
    expect(context).to be_valid
  end

  it 'requires the merchant number, certificate serial, APIv3 key and private key' do
    context = described_class.new

    expect(context).not_to be_valid
    expect(context.errors.attribute_names).to include(
      :merchant_id, :certificate_serial, :api_v3_key, :private_key_pem
    )
  end

  describe 'application identifiers' do
    it 'resolves one per scene, because they are three different identities' do
      expect(context.app_id_for('jsapi')).to eq('wx_jsapi_appid')
      expect(context.app_id_for('mini_program')).to eq('wx_mini_appid')
      expect(context.app_id_for('app')).to eq('wx_app_appid')
    end

    # Native and H5 carry no payer identity, but WeChat still requires an
    # `appid` on the request — any of the three kinds, as long as it is bound to
    # the merchant number.
    it 'falls back to the bound identifier for a scene with no identity of its own' do
      expect(context.app_id_for('native')).to eq(WechatPaySpecHelpers::BOUND_APP_ID)
      expect(context.app_id_for('h5')).to eq(WechatPaySpecHelpers::BOUND_APP_ID)
    end

    it 'has no identifier for a scene that does not exist' do
      expect(context.app_id_for('micropay')).to be_nil
    end
  end

  describe '#transaction_path' do
    it 'maps each scene to its endpoint' do
      expect(context.transaction_path('native')).to eq('/v3/pay/transactions/native')
      expect(context.transaction_path('h5')).to eq('/v3/pay/transactions/h5')
      expect(context.transaction_path('app')).to eq('/v3/pay/transactions/app')
    end

    # One endpoint serves both, which is why they are one integration rather
    # than two.
    it 'gives JSAPI and the mini program the same endpoint' do
      expect(context.transaction_path('jsapi')).to eq(context.transaction_path('mini_program'))
    end

    it 'refuses a scene it does not know' do
      expect { context.transaction_path('micropay') }.to raise_error(ArgumentError, /micropay/)
    end
  end

  describe 'verification mode' do
    it 'requires the public key and its id when that is the mode' do
      context = merchant_context(public_key_pem: nil, public_key_id: nil)

      expect(context).not_to be_valid
      expect(context.errors.attribute_names).to include(:public_key_pem, :public_key_id)
    end

    it 'does not require them in platform certificate mode' do
      context = merchant_context(
        verification_mode: 'platform_certificate', public_key_pem: nil, public_key_id: nil
      )

      expect(context).to be_valid
    end
  end

  describe '#signer' do
    it 'builds a signer from the parsed private key' do
      expect(context.signer).to be_a(SpreeWechatPay::Signer)
    end

    it 'raises when the private key is not a key' do
      context = merchant_context(private_key_pem: 'not a key')

      expect { context.private_key }.to raise_error(OpenSSL::PKey::RSAError)
    end
  end
end
