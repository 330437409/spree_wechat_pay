module SpreeWechatPay
  # `AEAD_AES_256_GCM` over a Base64 envelope — the shape WeChat Pay uses for
  # both notification payloads and platform certificate downloads, which is why
  # it is one primitive rather than two.
  #
  # The envelope carries everything needed except the key: the nonce, the
  # associated data (documented as possibly empty) and the ciphertext, whose
  # final sixteen bytes are the authentication tag.
  module Aead
    class Error < StandardError; end

    KEY_LENGTH = 32
    TAG_LENGTH = 16

    # @param envelope [Hash] `ciphertext`, `nonce`, `associated_data`
    # @param key [String] the 32-character APIv3 key
    # @return [String] the decrypted plaintext
    # @raise [Error]
    def self.decrypt(envelope:, key:)
      raise Error, 'APIv3 key is not 32 bytes' unless key.to_s.bytesize == KEY_LENGTH

      ciphertext = Base64.strict_decode64(envelope['ciphertext'].to_s)
      raise Error, 'Ciphertext is too short to carry an authentication tag' if ciphertext.bytesize <= TAG_LENGTH

      cipher = OpenSSL::Cipher.new('aes-256-gcm')
      cipher.decrypt
      cipher.key = key
      cipher.iv = envelope['nonce'].to_s
      cipher.auth_tag = ciphertext[-TAG_LENGTH..]
      # OpenSSL treats empty auth_data as absent, which is what WeChat means by
      # an empty associated_data.
      cipher.auth_data = envelope['associated_data'].to_s

      (cipher.update(ciphertext[0...-TAG_LENGTH]) + cipher.final).force_encoding('UTF-8')
    rescue OpenSSL::Cipher::CipherError
      # A wrong key and a tampered body are indistinguishable, and both mean the
      # same thing to a caller: do not trust this payload.
      raise Error, 'Payload could not be decrypted'
    rescue ArgumentError
      raise Error, 'Malformed ciphertext encoding'
    end
  end
end
