source 'https://rubygems.org'

# The Spree release this gateway is built against. Pinned exactly: the
# payment-session contract it implements is still moving through 6.0.
gem 'spree', '6.0.0.rc3'

gem 'rails', '~> 8.1.0', require: false
# json 3.0 made JSON.parse's options keyword-only, and Active Support 8.1 still
# passes them positionally — which is every JSON column Spree reads.
gem 'json', '< 3'
gem 'sqlite3', '>= 2.0'

group :test do
  gem 'database_cleaner-active_record'
  gem 'factory_bot_rails', '~> 6.2.0'
  gem 'ffaker'
  gem 'rspec-rails'
  gem 'timecop'
  gem 'webmock'
end

group :test, :development do
  gem 'observer'
  gem 'puma'
end

gemspec
