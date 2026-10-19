require 'webmock/rspec'

# Nothing in this suite talks to WeChat. Signing and verification are proved
# with a locally generated key pair, encryption round-trips through the same
# OpenSSL the production path uses, and the HTTP layer is exercised through
# Faraday's test adapter. A real request means a spec is reaching somewhere it
# should not, and it should fail loudly rather than quietly depend on a network.
WebMock.disable_net_connect!(allow_localhost: true)

# Core geocodes a warehouse whenever one is saved, and this suite drains the
# queue — so the lookup is stubbed here the way every WeChat endpoint is, and
# for the same reason: a spec that reaches the network should fail loudly rather
# than depend on it. WebMock's refusal is deliberately not a StandardError, so
# nothing can swallow it: the call has to not be made.
RSpec.configure do |config|
  config.before { allow(Geocoder).to receive(:coordinates).and_return(nil) }
end
