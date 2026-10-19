require 'spec_helper'

RSpec.describe SpreeWechatPay::RefreshCertificatesJob do
  describe '#perform' do
    it 'refreshes gateways configured for platform certificates' do
      gateway = wechat_gateway(verification_mode: 'platform_certificate')
      store = instance_double(SpreeWechatPay::CertificateStore, refresh!: 1)
      allow(gateway).to receive(:certificate_store).and_return(store)
      allow(SpreeWechatPay::Gateway).to receive(:find_each).and_yield(gateway)

      described_class.new.perform

      expect(store).to have_received(:refresh!)
    end

    it 'skips gateways that verify against the configured public key' do
      gateway = wechat_gateway
      allow(SpreeWechatPay::Gateway).to receive(:find_each).and_yield(gateway)

      expect(gateway).not_to receive(:certificate_store)

      described_class.new.perform
    end

    it 'reports a failing gateway and still refreshes the rest' do
      failing = wechat_gateway(verification_mode: 'platform_certificate')
      healthy = wechat_gateway(verification_mode: 'platform_certificate')
      failing_store = instance_double(SpreeWechatPay::CertificateStore)
      healthy_store = instance_double(SpreeWechatPay::CertificateStore, refresh!: 1)
      allow(failing).to receive(:certificate_store).and_return(failing_store)
      allow(healthy).to receive(:certificate_store).and_return(healthy_store)
      allow(failing_store).to receive(:refresh!).and_raise(
        SpreeWechatPay::ConnectionError.new('WeChat Pay answered 500')
      )
      allow(SpreeWechatPay::Gateway).to receive(:find_each).and_yield(failing).and_yield(healthy)
      expect(Rails.error).to receive(:report).with(
        an_instance_of(SpreeWechatPay::ConnectionError),
        handled: true,
        context: { payment_method_id: failing.id },
        source: 'spree_wechat_pay'
      )

      described_class.new.perform

      expect(healthy_store).to have_received(:refresh!)
    end

    # WeChat is not answering at all, so the next gateway would be refused just
    # as fast and reported for nothing. The next scheduled run picks the sweep
    # up once the circuit has had time to close.
    it 'stops the sweep while the circuit is open' do
      gateway = wechat_gateway(verification_mode: 'platform_certificate')
      store = instance_double(SpreeWechatPay::CertificateStore)
      allow(gateway).to receive(:certificate_store).and_return(store)
      allow(store).to receive(:refresh!).and_raise(SpreeWechatPay::CircuitOpenError)
      allow(SpreeWechatPay::Gateway).to receive(:find_each).and_yield(gateway)
      expect(Rails.error).not_to receive(:report)

      described_class.new.perform
    end
  end
end
