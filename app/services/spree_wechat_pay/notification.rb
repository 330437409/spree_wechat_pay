module SpreeWechatPay
  # A notification from WeChat: a JSON envelope whose `resource` is an
  # encrypted payload.
  #
  # Everything the merchant acts on — the transaction, the refund — arrives
  # inside `resource`, encrypted with the APIv3 key. The envelope itself is
  # legible; only what it carries is not.
  class Notification
    # @param envelope [Hash] the parsed JSON envelope
    # @param api_v3_key [String] the merchant's 32-character APIv3 key
    def initialize(envelope:, api_v3_key:)
      @envelope = envelope
      @api_v3_key = api_v3_key
    end

    # @return [String, nil]
    def event_type
      @envelope['event_type']
    end

    # @return [String, nil] `transaction` or `refund`
    def original_type
      resource_envelope['original_type']
    end

    # The decrypted payload, parsed.
    #
    # @return [Hash]
    # @raise [SpreeWechatPay::Aead::Error]
    def resource
      @resource ||= JSON.parse(decrypt)
    rescue JSON::ParserError
      raise Aead::Error, 'Decrypted payload is not JSON'
    end

    # Whether this envelope is one this gateway knows how to read. WeChat has
    # many notification families and the callback URL is shared, so an envelope
    # that is not an encrypted resource is acknowledged rather than acted on.
    #
    # @return [Boolean]
    def readable?
      @envelope['resource_type'] == ENVELOPE_RESOURCE_TYPE &&
        resource_envelope['algorithm'] == ENVELOPE_ALGORITHM
    end

    private

    def resource_envelope
      @envelope['resource'] || {}
    end

    def decrypt
      raise Aead::Error, 'Notification is not an encrypted resource' unless readable?

      Aead.decrypt(envelope: resource_envelope, key: @api_v3_key)
    end
  end
end
