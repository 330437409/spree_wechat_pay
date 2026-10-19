module SpreeWechatPay
  class Gateway < ::Spree::Gateway
    # Verifying and reading WeChat's notifications.
    #
    # WeChat has no endpoint registration and no per-endpoint signing secret:
    # every transaction carries the `notify_url` it wants notified at, and the
    # signature is verified against the merchant's public key or a platform
    # certificate. So there is nothing to register and nothing to store beyond
    # the credentials themselves.
    module Webhooks
      extend ActiveSupport::Concern

      # WeChat's payment notifications are only ever sent for a payment that
      # succeeded; failures and closures are discovered by querying. Subscribing
      # to more would mean handling events that never arrive.
      PAYMENT_EVENT_ACTIONS = {
        'TRANSACTION.SUCCESS' => :captured
      }.freeze

      # Translates a WeChat notification into the shape core consumes.
      # Everything after this — idempotency, locking, payment creation, order
      # completion — belongs to core.
      #
      # @param raw_body [String] the exact bytes received
      # @param headers [Hash] the request headers
      # @return [Hash, nil] nil for an event this gateway does not act on
      # @raise [Spree::PaymentMethod::WebhookSignatureError]
      def parse_webhook_event(raw_body, headers)
        verify_webhook_signature(raw_body, headers)

        envelope = parse_envelope(raw_body)
        return nil if envelope.nil?

        notification = Notification.new(envelope: envelope, api_v3_key: merchant_context.api_v3_key)
        return nil unless notification.readable?

        action = PAYMENT_EVENT_ACTIONS[notification.event_type]
        # A refund notification, or any other family arriving at the same
        # callback URL, is acknowledged without being acted on. WeChat stops
        # retrying on a 200, which is what a shared URL depends on.
        return nil unless action

        parse_payment_event(notification, action)
      end

      private

      def parse_payment_event(notification, action)
        resource = notification.resource
        payment_session = Spree::PaymentSessions::WechatPay.find_by(
          payment_method: self,
          external_id: resource['out_trade_no']
        )
        # A notification for a transaction this store does not own is
        # acknowledged without being acted on, which is what a callback URL
        # shared by several stores depends on.
        return nil if payment_session.nil?

        {
          action: action,
          payment_session: payment_session,
          # WeChat's own identifiers for what just happened, for core to record
          # on the payment. Core's webhook controller does not forward them
          # today, so they land only on the synchronous path.
          metadata: payment_metadata(resource)
        }
      end

      def verify_webhook_signature(raw_body, headers)
        notification_verifier.verify!(
          body: raw_body,
          timestamp: header(headers, 'Wechatpay-Timestamp').to_s,
          nonce: header(headers, 'Wechatpay-Nonce').to_s,
          signature: header(headers, 'Wechatpay-Signature').to_s,
          serial: header(headers, 'Wechatpay-Serial').to_s
        )
      rescue Verifier::InvalidSignature => error
        raise Spree::PaymentMethod::WebhookSignatureError, error.message
      end

      # Headers arrive as Rack's `HTTP_` form from a request and as plain names
      # from anything else, so both are accepted rather than making every caller
      # remember which it is holding.
      def header(headers, name)
        rack_name = "HTTP_#{name.upcase.tr('-', '_')}"

        headers[rack_name].presence || headers[name].presence
      end

      def parse_envelope(raw_body)
        JSON.parse(raw_body)
      rescue JSON::ParserError
        # Unauthenticated garbage is a rejected webhook, not a server error to
        # retry — and the signature was already checked, so this is a body that
        # verified but is not the JSON it claims to be.
        raise Spree::PaymentMethod::WebhookSignatureError, 'Malformed webhook payload'
      end
    end
  end
end
