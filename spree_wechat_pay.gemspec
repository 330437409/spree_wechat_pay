# encoding: UTF-8

require_relative 'lib/spree_wechat_pay/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name         = 'spree_wechat_pay'
  s.version      = SpreeWechatPay::VERSION
  s.authors      = ['Vendo Connect Inc.', 'Vendo Sp. z o.o.']
  s.email        = 'hello@spreecommerce.org'
  s.summary      = 'Official WeChat Pay payment gateway for Spree Commerce'
  s.description  = 'Optional WeChat Pay gateway for Spree, implementing the payment session API'
  s.homepage     = 'https://spreecommerce.org'
  s.license      = 'BSD-3-Clause'

  s.metadata = {
    "bug_tracker_uri"   => "https://github.com/330437409/spree_wechat_pay/issues",
    "changelog_uri"     => "https://github.com/330437409/spree_wechat_pay/releases/tag/v#{s.version}",
    "documentation_uri" => "https://docs.spreecommerce.org/",
    "source_code_uri"   => "https://github.com/330437409/spree_wechat_pay/tree/v#{s.version}",
  }

  s.required_ruby_version = '>= 3.2'

  s.files        = Dir["{app,config,db,lib,vendor}/**/*", "Rakefile", "README.md", "LICENSE"].reject { |f| f.match(/^spec/) && !f.match(/^spec\/fixtures/) }
  s.require_path = 'lib'

  s.add_dependency 'spree_core', ">= #{s.version}"
  # WeChat Pay publishes no official Ruby SDK (Java, PHP and Go only) and no
  # maintained community gem, so the signature, verification and notification
  # decryption are implemented here against Faraday.
  s.add_dependency 'faraday', '>= 2.0', '< 3'
  # Signatures and encrypted notification bodies are Base64 on the wire. This
  # stopped being a default gem in Ruby 3.4, so it is declared rather than
  # assumed.
  s.add_dependency 'base64'

  s.add_development_dependency 'vcr'
end
