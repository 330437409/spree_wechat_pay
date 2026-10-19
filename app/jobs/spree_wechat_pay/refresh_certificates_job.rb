module SpreeWechatPay
  # Re-downloads WeChat's platform certificates on a schedule, so a rotated
  # certificate is cached before the 24-hour overlap that kept the old one in
  # use closes. Without this the webhook path would keep verifying against a
  # certificate WeChat stopped signing with, and every notification would fail
  # until an operator cleared the cache by hand.
  #
  # A public key gateway is skipped: its key never rotates and needs nothing
  # from the network.
  class RefreshCertificatesJob < BaseJob
    include ActiveJob::Continuable

    # The cursor is the last gateway refreshed. A sweep that spans a deploy
    # resumes at the next gateway instead of downloading every certificate set
    # again, which matters on the day a rotation actually happens.
    def perform
      step :refresh_certificates
    end

    private

    def refresh_certificates(step)
      SpreeWechatPay::Gateway.find_each(start: step.cursor) do |gateway|
        refresh(gateway)
        step.advance! from: gateway.id
      end
    rescue CircuitOpenError
      # WeChat is refusing every call, so the next gateway would be refused just
      # as fast and reported for nothing. The next scheduled run picks the sweep
      # up once the circuit has had time to close.
      return
    end

    def refresh(gateway)
      return unless gateway.preferred_verification_mode == 'platform_certificate'

      gateway.certificate_store.refresh!
    rescue CircuitOpenError
      raise
    rescue StandardError => error
      # One misconfigured gateway must not stop the sweep from refreshing the
      # rest, so each failure is reported and the job moves on.
      Rails.error.report(
        error,
        handled: true,
        context: { payment_method_id: gateway.id },
        source: 'spree_wechat_pay'
      )
    end
  end
end
