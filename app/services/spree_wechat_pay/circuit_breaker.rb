module SpreeWechatPay
  # Refuses to call WeChat once it has failed repeatedly, so an outage costs one
  # timeout per worker rather than one per request.
  #
  # The state lives in `Rails.cache` rather than in the process, because the
  # point is to reach the workers that have not yet made a failing call. A cache
  # that cannot hold state — a null store — leaves the breaker closed, which is
  # the safe direction: it exists to shed load, never to be the reason a call is
  # not made.
  #
  # One breaker per merchant account, so an account WeChat is rejecting does not
  # silence the store's other WeChat Pay payment methods.
  class CircuitBreaker
    # Failures in a row before calls stop being made.
    FAILURE_THRESHOLD = 5

    # How long calls are refused once it has opened. The first call after this
    # is a probe: a success closes the breaker, a failure opens it again.
    OPEN_FOR = 1.minute

    # How long a failure counts towards the threshold, so one bad afternoon does
    # not add up to an open breaker tomorrow.
    FAILURE_WINDOW = 5.minutes

    # @param merchant_id [String, nil] the WeChat merchant account
    # @param cache [ActiveSupport::Cache::Store]
    def initialize(merchant_id, cache: Rails.cache)
      @merchant_id = merchant_id
      @cache = cache
    end

    # @return [Boolean] true while calls should be refused without being made
    def open?
      cache.exist?(open_key)
    end

    def record_success
      cache.delete(failures_key)
      cache.delete(open_key)
    end

    def record_failure
      failures = cache.read(failures_key).to_i + 1
      cache.write(failures_key, failures, expires_in: FAILURE_WINDOW)
      cache.write(open_key, true, expires_in: OPEN_FOR) if failures >= FAILURE_THRESHOLD
    end

    private

    attr_reader :merchant_id, :cache

    def failures_key
      "spree_wechat_pay/circuit/#{merchant_id}/failures"
    end

    def open_key
      "spree_wechat_pay/circuit/#{merchant_id}/open"
    end
  end
end
