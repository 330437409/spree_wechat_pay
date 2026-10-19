require 'spec_helper'

RSpec.describe SpreeWechatPay::Notification do
  let(:api_v3_key) { WechatPaySpecHelpers::API_V3_KEY }
  let(:transaction) do
    {
      'out_trade_no' => 'R123456789-abc',
      'transaction_id' => '4200001234202601011234567890',
      'trade_state' => 'SUCCESS',
      'payer' => { 'openid' => 'oUpF8uMuAJO_M2pxb1Q9zNjWeS6o' }
    }
  end

  def envelope(event_type: 'TRANSACTION.SUCCESS', original_type: 'transaction', payload: transaction)
    {
      'id' => 'EV-2018022511223320873',
      'create_time' => '2026-09-10T13:29:35+08:00',
      'resource_type' => 'encrypt-resource',
      'event_type' => event_type,
      'summary' => '支付成功',
      'resource' => encrypt_like_wechat(
        JSON.generate(payload), key: api_v3_key, associated_data: original_type
      ).merge('original_type' => original_type)
    }
  end

  subject(:notification) { described_class.new(envelope: envelope, api_v3_key: api_v3_key) }

  it 'reads the event type from the envelope, which is not encrypted' do
    expect(notification.event_type).to eq('TRANSACTION.SUCCESS')
  end

  it 'reads which kind of resource it carries' do
    expect(notification.original_type).to eq('transaction')
  end

  it 'decrypts the payload' do
    expect(notification.resource).to eq(transaction)
  end

  it 'reads a refund notification through the same envelope' do
    refund = { 'out_refund_no' => 'REF-123', 'refund_status' => 'SUCCESS' }
    notification = described_class.new(
      envelope: envelope(event_type: 'REFUND.SUCCESS', original_type: 'refund', payload: refund),
      api_v3_key: api_v3_key
    )

    expect(notification.original_type).to eq('refund')
    expect(notification.resource).to eq(refund)
  end

  describe '#readable?' do
    it 'accepts an encrypted resource' do
      expect(notification).to be_readable
    end

    # WeChat has many notification families and the callback URL is shared, so
    # anything else is acknowledged without being acted on.
    it 'refuses an envelope that is not an encrypted resource' do
      notification = described_class.new(
        envelope: { 'event_type' => 'SOMETHING.ELSE', 'resource_type' => 'plain' },
        api_v3_key: api_v3_key
      )

      expect(notification).not_to be_readable
      expect { notification.resource }.to raise_error(SpreeWechatPay::Aead::Error, /not an encrypted resource/)
    end

    it 'refuses an algorithm it does not implement' do
      notification = described_class.new(
        envelope: envelope.merge(
          'resource' => envelope['resource'].merge('algorithm' => 'AEAD_AES_128_GCM')
        ),
        api_v3_key: api_v3_key
      )

      expect(notification).not_to be_readable
    end
  end

  it 'raises when the APIv3 key is wrong rather than returning garbage' do
    notification = described_class.new(envelope: envelope, api_v3_key: 'b' * 32)

    expect { notification.resource }.to raise_error(SpreeWechatPay::Aead::Error, /could not be decrypted/)
  end

  it 'raises when the decrypted payload is not JSON' do
    notification = described_class.new(
      envelope: envelope.merge(
        'resource' => encrypt_like_wechat('not json', key: api_v3_key)
          .merge('original_type' => 'transaction')
      ),
      api_v3_key: api_v3_key
    )

    expect { notification.resource }.to raise_error(SpreeWechatPay::Aead::Error, /not JSON/)
  end
end
