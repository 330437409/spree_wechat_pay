require 'spec_helper'

RSpec.describe SpreeWechatPay::CircuitBreaker do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:breaker) { described_class.new(WechatPaySpecHelpers::MERCHANT_ID, cache: cache) }

  # Short of the threshold the calls keep being made: the breaker is there to
  # stop an outage, not to react to a single bad reply.
  it 'stays closed while the failures are short of the threshold' do
    (described_class::FAILURE_THRESHOLD - 1).times { breaker.record_failure }

    expect(breaker).not_to be_open
  end

  it 'opens once the failures reach the threshold' do
    described_class::FAILURE_THRESHOLD.times { breaker.record_failure }

    expect(breaker).to be_open
  end

  # Otherwise a bad morning would keep the breaker open all day.
  it 'counts a success as a fresh start' do
    (described_class::FAILURE_THRESHOLD - 1).times { breaker.record_failure }
    breaker.record_success
    breaker.record_failure

    expect(breaker).not_to be_open
  end

  # After the open period the next call is a probe. If it fails the breaker
  # opens again at once rather than starting its count over.
  it 'lets one call through when the open period has passed' do
    described_class::FAILURE_THRESHOLD.times { breaker.record_failure }

    Timecop.travel(described_class::OPEN_FOR + 1.second) do
      expect(breaker).not_to be_open

      breaker.record_failure

      expect(breaker).to be_open
    end
  end

  # A failure that has aged out must not add up with today's.
  it 'forgets failures older than the window' do
    (described_class::FAILURE_THRESHOLD - 1).times { breaker.record_failure }

    Timecop.travel(described_class::FAILURE_WINDOW + 1.second) do
      breaker.record_failure

      expect(breaker).not_to be_open
    end
  end

  # A merchant account WeChat is rejecting must not silence the store's other
  # WeChat Pay payment methods.
  it 'counts each merchant account separately' do
    described_class::FAILURE_THRESHOLD.times { breaker.record_failure }

    expect(described_class.new('1900000002', cache: cache)).not_to be_open
  end
end
