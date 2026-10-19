require 'spec_helper'

RSpec.describe SpreeWechatPay::Aead do
  let(:key) { WechatPaySpecHelpers::API_V3_KEY }

  def envelope_for(plaintext, associated_data: 'transaction')
    encrypt_like_wechat(plaintext, key: key, associated_data: associated_data)
  end

  describe '.decrypt' do
    it 'round-trips a payload' do
      plaintext = '{"out_trade_no":"R123456789"}'

      expect(described_class.decrypt(envelope: envelope_for(plaintext), key: key)).to eq(plaintext)
    end

    it 'decrypts a payload whose associated data is empty' do
      plaintext = '{"out_trade_no":"R123456789"}'
      envelope = envelope_for(plaintext, associated_data: '')

      expect(described_class.decrypt(envelope: envelope, key: key)).to eq(plaintext)
    end

    # The published AES-256-GCM test vectors (McGrew & Viega, "The Galois/Counter
    # Mode of Operation", test case 2). This is the only assertion in the suite
    # that does not come from this codebase's own encryption, so it is what
    # catches a construction error that a round trip would hide.
    it 'matches a published AES-256-GCM test vector' do
      envelope = {
        'ciphertext' => Base64.strict_encode64(
          ['cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919'].pack('H*')
        ),
        'nonce' => "\x00" * 12,
        'associated_data' => ''
      }

      expect(described_class.decrypt(envelope: envelope, key: "\x00" * 32)).to eq("\x00" * 16)
    end

    it 'rejects a payload encrypted with a different key' do
      envelope = encrypt_like_wechat('{}', key: 'a' * 32)

      expect do
        described_class.decrypt(envelope: envelope, key: key)
      end.to raise_error(described_class::Error, /could not be decrypted/)
    end

    it 'rejects a key that is not 32 bytes' do
      expect do
        described_class.decrypt(envelope: envelope_for('{}'), key: 'short')
      end.to raise_error(described_class::Error, /not 32 bytes/)
    end

    it 'rejects a body whose plaintext was altered, because the tag covers it' do
      envelope = envelope_for('{"amount":100}')
      raw = Base64.strict_decode64(envelope['ciphertext'])
      envelope['ciphertext'] = Base64.strict_encode64(raw.tap { |v| v.setbyte(0, v.getbyte(0) ^ 0x01) })

      expect do
        described_class.decrypt(envelope: envelope, key: key)
      end.to raise_error(described_class::Error, /could not be decrypted/)
    end

    it 'rejects altered associated data, because the tag covers that too' do
      envelope = envelope_for('{}', associated_data: 'transaction')
      envelope['associated_data'] = 'refund'

      expect do
        described_class.decrypt(envelope: envelope, key: key)
      end.to raise_error(described_class::Error, /could not be decrypted/)
    end

    it 'rejects a ciphertext too short to carry a tag' do
      envelope = { 'ciphertext' => Base64.strict_encode64('short'), 'nonce' => 'x' * 12 }

      expect do
        described_class.decrypt(envelope: envelope, key: key)
      end.to raise_error(described_class::Error, /too short/)
    end

    it 'rejects ciphertext that is not Base64' do
      envelope = { 'ciphertext' => 'not base64!!', 'nonce' => 'x' * 12, 'associated_data' => '' }

      expect do
        described_class.decrypt(envelope: envelope, key: key)
      end.to raise_error(described_class::Error, /Malformed ciphertext/)
    end
  end
end
