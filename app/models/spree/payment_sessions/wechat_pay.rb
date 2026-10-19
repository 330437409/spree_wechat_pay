module Spree
  class PaymentSessions::WechatPay < PaymentSession
    # `payment_source_for_settlement` stays nil: WeChat issues no reusable
    # instrument for one-off payments, so the payment stands on its own.
    #
    # WeChat's own numbers — the transaction id, its state, the payer — are what
    # `prepare_for_settlement!` reads and `apply_settlement_metadata` writes. The
    # notification core parsed carries them, but core's webhook controller does
    # not pass that metadata through to settlement, so on the webhook path they
    # are read back from WeChat.

    # WeChat's identifiers for this transaction, warmed before the settlement
    # lock so the locked settlement does no provider I/O.
    #
    # @return [Spree::PaymentSession] self
    def prepare_for_settlement!
      @transaction_metadata = payment_method.transaction_metadata_for(merchant_order_number)

      self
    rescue SpreeWechatPay::ApiError, SpreeWechatPay::ConnectionError => error
      # Bookkeeping must not hold up recording money that has already moved: a
      # payment WeChat reports as paid is settled without its identifiers, and
      # the notification WeChat is retrying brings another chance.
      Rails.error.report(
        error,
        handled: true,
        context: { payment_session_id: id },
        source: 'spree_wechat_pay'
      )

      self
    end

    # Keeps WeChat's own identifiers alongside whatever the caller passed — the
    # confirm path passes them, the webhook path arrives empty and reads them in
    # `prepare_for_settlement!` instead.
    #
    # @param payment [Spree::Payment] unsaved
    # @param metadata [Hash]
    # @return [void]
    def apply_settlement_metadata(payment, metadata)
      super

      payment.metadata.merge!(@transaction_metadata) if @transaction_metadata.present?
    end

    # Our merchant order number for WeChat.
    #
    # @return [String]
    def merchant_order_number
      external_id
    end

    # @return [String, nil] `native`, `jsapi`, ...
    def scene
      external_data&.dig('scene')
    end

    # The scene object the transaction was placed with — the customer's device
    # type and IP, for H5. Read back on a re-issue, which WeChat refuses unless
    # every parameter matches the request that created the transaction.
    #
    # @return [Hash, nil]
    def scene_info
      external_data&.dig('scene_info')
    end

    # The QR link a Native customer scans. Not a fixed value — render it as a
    # QR code rather than storing or comparing it.
    #
    # @return [String, nil]
    def code_url
      external_data&.dig('code_url')
    end

    # The redirect link an H5 customer is sent to. Like the Native code URL, not
    # a fixed value — redirect to it rather than storing or comparing it.
    #
    # @return [String, nil]
    def h5_url
      external_data&.dig('h5_url')
    end

    # WeChat's own identifier for the transaction, known only once it is paid.
    #
    # @return [String, nil]
    def transaction_id
      external_data&.dig('transaction_id')
    end

    # @return [String, nil]
    def openid
      external_data&.dig('openid')
    end

    # When the launch token lapses — two hours for `code_url` and `prepay_id`,
    # five minutes for H5's URL.
    #
    # This is not the session's own expiry, which follows the transaction's
    # payability. A lapsed token is renewed, not fatal.
    #
    # Deliberately not memoized: renewal rewrites this attribute on the same
    # instance, and a cached value would keep reporting the old token as lapsed
    # — sending the storefront into a renewal loop.
    #
    # @return [Time, nil]
    def payload_expires_at
      raw = external_data&.dig('payload_expires_at')
      raw.present? ? Time.iso8601(raw) : nil
    rescue ArgumentError
      # Written by us, so an unparseable value means the record was edited
      # outside the app. Treating it as absent is safer than raising on every
      # read of an old session.
      nil
    end

    # @return [Boolean]
    def payload_expired?
      payload_expires_at.present? && payload_expires_at <= Time.current
    end

    # Keeps WeChat's own identifiers on the session once they are known. They
    # only exist after payment, so a session created a moment ago has neither.
    #
    # Called from the synchronous confirmation path, where a query has just
    # answered; the notification path records the same values on the payment
    # instead, through the metadata the gateway returns.
    #
    # @param response [Hash] a query or notification payload
    # @return [void]
    def record_wechat_response(response)
      recorded = {
        'transaction_id' => response['transaction_id'],
        'openid' => response.dig('payer', 'openid')
      }.compact_blank

      return if recorded.empty?

      update!(external_data: (external_data || {}).merge(recorded))
    end
  end
end
