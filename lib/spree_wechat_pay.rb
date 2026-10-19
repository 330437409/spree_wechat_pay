require 'base64'
require 'faraday'
require 'openssl'
require 'securerandom'
require 'spree_core'
require 'spree_wechat_pay/engine'

module SpreeWechatPay
  # WeChat Pay's v3 API host. The documented backup host is
  # `https://api2.mch.weixin.qq.com`, used when the primary is unreachable from
  # a given network; not wired up yet.
  API_HOST = 'https://api.mch.weixin.qq.com'.freeze

  # Every notification WeChat sends carries the same envelope shape, and the
  # payment and refund notifications differ only in what is inside the
  # encrypted resource.
  ENVELOPE_RESOURCE_TYPE = 'encrypt-resource'.freeze
  ENVELOPE_ALGORITHM = 'AEAD_AES_256_GCM'.freeze

  # Preview of the identifier WeChat uses for a merchant's public key in the
  # `Wechatpay-Serial` header. A serial that does not match this shape names a
  # platform certificate instead.
  PUBLIC_KEY_ID_PREFIX = 'PUB_KEY_ID_'.freeze

  # Background queue for the gem's jobs. Defaults to Spree's default queue.
  def self.queue
    @queue ||= Spree.queues.default
  end

  class << self
    attr_writer :queue
  end
end
