require 'spec_helper'

RSpec.describe SpreeWechatPay::Refund do
  let(:context) { merchant_context }
  let(:client) { instance_double(SpreeWechatPay::Client) }
  let(:refund_number) { 're_test-ABCDEF12' }
  let(:refund) { described_class.new(context: context, client: client, merchant_refund_number: refund_number) }

  describe '#create' do
    it 'submits the refund to the domestic refund endpoint' do
      payload = { 'out_trade_no' => 'R1001-abcd1234', 'amount' => { 'refund' => 1, 'total' => 2, 'currency' => 'CNY' } }
      expect(client).to receive(:post).with('/v3/refund/domestic/refunds', payload).and_return('refund_id' => 'r1')

      expect(refund.create(payload)).to eq('refund_id' => 'r1')
    end
  end

  describe '#query' do
    it 'queries by the merchant refund number' do
      expect(client).to receive(:get).with("/v3/refund/domestic/refunds/#{refund_number}")
        .and_return('refund_id' => 'r1', 'status' => 'SUCCESS')

      expect(refund.query['status']).to eq('SUCCESS')
    end
  end
end
