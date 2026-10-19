module SpreeWechatPay
  # RSA-OAEP over sensitive fields — a payer's real name, an address, a card
  # number. WeChat Pay v3 requires such fields to be encrypted on the way in and
  # returns its own sensitive fields encrypted on the way out, and the two halves
  # use different keys:
  #
  # - Encrypt with the WeChat Pay public key (or a platform certificate's public
  #   key), so only WeChat, holding the private half, can read it.
  # - Decrypt with the merchant certificate's private key, because WeChat
  #   encrypted the field against the merchant certificate's public key.
  #
  # The padding is OAEP with SHA-1, which is WeChat's documented mode and what
  # OpenSSL's `RSA_PKCS1_OAEP_PADDING` means.
  module SensitiveField
    # @param plaintext [String]
    # @param key [OpenSSL::PKey::RSA] the WeChat Pay public key or a platform
    #   certificate's public key
    # @return [String] Base64 ciphertext
    def self.encrypt(plaintext, key:)
      Base64.strict_encode64(
        key.public_encrypt(plaintext.to_s, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
      )
    end

    # @param ciphertext [String] Base64
    # @param key [OpenSSL::PKey::RSA] the merchant certificate's private key
    # @return [String] the plaintext
    def self.decrypt(ciphertext, key:)
      key.private_decrypt(
        Base64.strict_decode64(ciphertext.to_s),
        OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING
      ).force_encoding('UTF-8')
    end
  end
end
