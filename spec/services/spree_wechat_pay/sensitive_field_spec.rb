require 'spec_helper'

RSpec.describe SpreeWechatPay::SensitiveField do
  let(:key_pair) { OpenSSL::PKey::RSA.new(2048) }
  let(:plaintext) { '张三' }

  describe '.encrypt' do
    it 'produces Base64 ciphertext' do
      ciphertext = described_class.encrypt(plaintext, key: key_pair.public_key)

      expect(Base64.strict_decode64(ciphertext)).to be_present
    end

    # OAEP is randomized, so encrypting the same plaintext twice must not repeat
    # — a fixed ciphertext would let an eavesdropper match fields by their hash.
    it 'never repeats itself' do
      expect(described_class.encrypt(plaintext, key: key_pair.public_key))
        .not_to eq(described_class.encrypt(plaintext, key: key_pair.public_key))
    end
  end

  describe '.decrypt' do
    it 'recovers the plaintext' do
      ciphertext = described_class.encrypt(plaintext, key: key_pair.public_key)

      expect(described_class.decrypt(ciphertext, key: key_pair)).to eq(plaintext)
    end

    it 'fails against a key that is not the pair' do
      ciphertext = described_class.encrypt(plaintext, key: key_pair.public_key)

      expect {
        described_class.decrypt(ciphertext, key: OpenSSL::PKey::RSA.new(2048))
      }.to raise_error(OpenSSL::PKey::RSAError)
    end
  end

  # The two directions use different keys, each matching the documented contract.
  describe 'the two directions' do
    it 'encrypts a field only WeChat can read' do
      ciphertext = described_class.encrypt(plaintext, key: platform_key_pair.public_key)

      expect(described_class.decrypt(ciphertext, key: platform_key_pair)).to eq(plaintext)
    end

    it 'decrypts a field WeChat encrypted against the merchant certificate' do
      ciphertext = described_class.encrypt(plaintext, key: merchant_key_pair.public_key)

      expect(described_class.decrypt(ciphertext, key: merchant_key_pair)).to eq(plaintext)
    end
  end
end
