require 'spec_helper'

RSpec.describe SpreeWechatPay::Transaction do
  let(:context) { merchant_context }
  let(:client) { instance_double(SpreeWechatPay::Client) }
  let(:number) { 'R1001-abcd1234' }
  let(:transaction) { described_class.new(context: context, client: client, merchant_order_number: number) }

  describe '#query' do
    # The query string is part of what WeChat signs, so it has to be in the path
    # the client signs and sends — a bare path here is refused with SIGN_ERROR.
    it 'asks by merchant order number, with the merchant number in the query' do
      expect(client).to receive(:get).with(
        "/v3/pay/transactions/out-trade-no/#{number}?mchid=#{WechatPaySpecHelpers::MERCHANT_ID}",
        any_args
      ).and_return('trade_state' => 'SUCCESS')

      transaction.query
    end

    it 'returns what WeChat reports' do
      allow(client).to receive(:get).and_return('trade_state' => 'SUCCESS')

      expect(transaction.query['trade_state']).to eq('SUCCESS')
    end
  end

  describe '#create' do
    it 'posts to the scene endpoint, not to one of its own' do
      expect(client).to receive(:post).with('/v3/pay/transactions/native', { 'a' => 1 })

      transaction.create(scene: 'native', payload: { 'a' => 1 })
    end

    it 'refuses a scene it does not know' do
      expect { transaction.create(scene: 'micropay', payload: {}) }.to raise_error(ArgumentError)
    end
  end

  describe '#close' do
    it 'closes by merchant order number, passing the merchant number in the body' do
      expect(client).to receive(:post).with(
        "/v3/pay/transactions/out-trade-no/#{number}/close",
        { 'mchid' => WechatPaySpecHelpers::MERCHANT_ID }
      )

      transaction.close
    end
  end

  # The state vocabulary is WeChat's, and the distinction that matters most is
  # that an unpaid transaction is not a failed one.
  describe 'state classification' do
    it 'treats SUCCESS and REFUND as paid' do
      expect(described_class.paid?('trade_state' => 'SUCCESS')).to be true
      expect(described_class.paid?('trade_state' => 'REFUND')).to be true
    end

    # A payment in flight. It is not settled, and it is not safe to retire
    # either — closing the transaction now would abort it.
    it 'treats USERPAYING as a payment in progress' do
      expect(described_class.paying?('trade_state' => 'USERPAYING')).to be true
      expect(described_class.paying?('trade_state' => 'NOTPAY')).to be false
      expect(described_class.paying?('trade_state' => 'SUCCESS')).to be false
    end

    it 'treats CLOSED and REVOKED as closed' do
      expect(described_class.closed?('trade_state' => 'CLOSED')).to be true
      expect(described_class.closed?('trade_state' => 'REVOKED')).to be true
    end

    it 'does not call an unpaid transaction paid' do
      expect(described_class.paid?('trade_state' => 'NOTPAY')).to be false
    end
  end
end
