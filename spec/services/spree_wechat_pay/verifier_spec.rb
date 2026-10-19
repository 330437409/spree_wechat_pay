require 'spec_helper'

RSpec.describe SpreeWechatPay::Verifier do
  let(:body) { '{"id":"EV-2018022511223320873","event_type":"TRANSACTION.SUCCESS"}' }
  let(:timestamp) { '1554208460' }
  let(:nonce) { 'NONCE_STRING' }
  let(:keys) { { WechatPaySpecHelpers::PUBLIC_KEY_ID => platform_key_pair.public_key } }
  let(:verifier) { described_class.new(keys, now: Time.zone.at(timestamp.to_i)) }

  def signature_for(body, timestamp, nonce, key: platform_key_pair)
    sign_like_wechat("#{timestamp}\n#{nonce}\n#{body}\n", key: key)
  end

  describe '#verify!' do
    it 'accepts a signature over the three-line string the specification defines' do
      expect(
        verifier.verify!(
          body: body, timestamp: timestamp, nonce: nonce,
          signature: signature_for(body, timestamp, nonce),
          serial: WechatPaySpecHelpers::PUBLIC_KEY_ID
        )
      ).to be true
    end

    it 'rejects a signature when the body was changed after signing' do
      signature = signature_for(body, timestamp, nonce)

      expect do
        verifier.verify!(
          body: '{"event_type":"TRANSACTION.SUCCESS"}', timestamp: timestamp, nonce: nonce,
          signature: signature, serial: WechatPaySpecHelpers::PUBLIC_KEY_ID
        )
      end.to raise_error(described_class::InvalidSignature, /does not match/)
    end

    it 'rejects a signature made with a different key' do
      other_key = OpenSSL::PKey::RSA.new(2048)

      expect do
        verifier.verify!(
          body: body, timestamp: timestamp, nonce: nonce,
          signature: signature_for(body, timestamp, nonce, key: other_key),
          serial: WechatPaySpecHelpers::PUBLIC_KEY_ID
        )
      end.to raise_error(described_class::InvalidSignature, /does not match/)
    end

    # During a certificate rotation WeChat signs with a certificate this
    # installation has not downloaded yet. Saying so is the difference between
    # an operator checking the refresh job and one staring at "invalid
    # signature".
    it 'names the missing serial rather than reporting a bad signature' do
      expect do
        verifier.verify!(
          body: body, timestamp: timestamp, nonce: nonce,
          signature: signature_for(body, timestamp, nonce),
          serial: WechatPaySpecHelpers::PLATFORM_SERIAL
        )
      end.to raise_error(described_class::InvalidSignature, /No verification key for serial #{WechatPaySpecHelpers::PLATFORM_SERIAL}/)
    end

    it 'rejects a request missing the verification headers' do
      expect do
        verifier.verify!(body: body, timestamp: nil, nonce: nonce, signature: 'x', serial: 'x')
      end.to raise_error(described_class::InvalidSignature, /Missing verification headers/)
    end

    it 'rejects a signature that is not Base64' do
      expect do
        verifier.verify!(
          body: body, timestamp: timestamp, nonce: nonce,
          signature: 'not base64!!', serial: WechatPaySpecHelpers::PUBLIC_KEY_ID
        )
      end.to raise_error(described_class::InvalidSignature, /Malformed signature encoding/)
    end
  end

  # A signature never expires on its own, so without this a notification
  # captured today would verify exactly as well tomorrow.
  describe 'the replay window' do
    def verify_within(offset)
      described_class.new(keys, now: Time.zone.at(timestamp.to_i) + offset).verify!(
        body: body, timestamp: timestamp, nonce: nonce,
        signature: signature_for(body, timestamp, nonce),
        serial: WechatPaySpecHelpers::PUBLIC_KEY_ID
      )
    end

    it 'accepts a signature made four minutes ago' do
      expect(verify_within(4.minutes)).to be true
    end

    it 'rejects a signature made six minutes ago' do
      expect { verify_within(6.minutes) }.to raise_error(described_class::InvalidSignature, /replay window/)
    end

    # A clock ahead of WeChat's produces a future timestamp as readily as a
    # forgery does, and a signature from the future is no more current.
    it 'rejects a signature dated more than five minutes ahead' do
      expect { verify_within(-6.minutes) }.to raise_error(described_class::InvalidSignature, /replay window/)
    end

    it 'rejects a timestamp that is not a number' do
      expect do
        described_class.new(keys).verify!(
          body: body, timestamp: 'yesterday', nonce: nonce,
          signature: signature_for(body, timestamp, nonce), serial: WechatPaySpecHelpers::PUBLIC_KEY_ID
        )
      end.to raise_error(described_class::InvalidSignature, /Malformed signature timestamp/)
    end
  end
end
