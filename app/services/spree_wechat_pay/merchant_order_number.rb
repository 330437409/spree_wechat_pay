module SpreeWechatPay
  # WeChat requires the merchant order number to be 6–32 characters from
  # `0-9a-zA-Z_-|*`, and unique within the merchant account.
  #
  # Spree's own identifiers do not satisfy that on their own. A cart's number is
  # its prefixed id — `cart_86Rf07xd4z` — which is the right length and the right
  # alphabet today but is derived, so its shape is not ours to promise. And a
  # number cannot be recycled once it has been paid, closed or reversed, while a
  # single cart can produce several payment attempts.
  #
  # So the number is Spree's identifier plus a random suffix: readable enough for
  # an operator reconciling against WeChat's bill, and unique enough that two
  # attempts never collide. The suffix is what guarantees uniqueness, so it is
  # never the part that gets truncated.
  class MerchantOrderNumber
    CHARSET = /\A[0-9A-Za-z_\-|*]+\z/
    MIN_LENGTH = 6
    MAX_LENGTH = 32
    # Long enough that a collision within one merchant account is not a
    # practical concern, short enough to leave room for the reference.
    SUFFIX_LENGTH = 8

    # Refund numbers obey their own rules: up to 64 bytes rather than 32
    # characters, and a wider alphabet where `@` is allowed.
    REFUND_CHARSET = /\A[0-9A-Za-z_\-|*@]+\z/
    REFUND_MAX_BYTES = 64
    REFUND_SUFFIX_LENGTH = 8

    class << self
      # @param owner [Spree::Cart, Spree::Order, Spree::PaymentSession, nil]
      # @param suffix [String] supplied by specs to pin the result
      # @return [String]
      def generate(owner, suffix: nil)
        suffix = sanitize(suffix || SecureRandom.alphanumeric(SUFFIX_LENGTH))
        suffix = suffix.first(SUFFIX_LENGTH) if suffix.length > SUFFIX_LENGTH

        reference = sanitize(reference_for(owner))
        room = MAX_LENGTH - suffix.length - 1
        reference = reference.first(room) if room.positive?
        reference = nil unless room.positive?

        [reference, suffix].compact_blank.join('-')
      end

      # @param owner [Spree::Refund, nil] the refund this number identifies
      # @param suffix [String] supplied by specs to pin the result
      # @return [String]
      def generate_refund(owner, suffix: nil)
        suffix = sanitize_refund(suffix || SecureRandom.alphanumeric(REFUND_SUFFIX_LENGTH))
        suffix = suffix.first(REFUND_SUFFIX_LENGTH) if suffix.length > REFUND_SUFFIX_LENGTH

        reference = sanitize_refund(reference_for(owner))
        room = REFUND_MAX_BYTES - suffix.bytesize - 1
        reference = reference.first(room) if room.positive?
        reference = nil unless room.positive?

        [reference, suffix].compact_blank.join('-')
      end

      # @param number [String]
      # @return [Boolean]
      def valid?(number)
        number.is_a?(String) &&
          number.length.between?(MIN_LENGTH, MAX_LENGTH) &&
          CHARSET.match?(number)
      end

      # @param number [String]
      # @return [Boolean]
      def valid_refund?(number)
        number.is_a?(String) &&
          number.bytesize <= REFUND_MAX_BYTES &&
          REFUND_CHARSET.match?(number)
      end

      private

      def reference_for(owner)
        return '' if owner.blank?

        # Carts and orders answer `number` with their human-readable number;
        # a refund has no number and is known by its prefixed id. Preferring
        # `number` keeps the WeChat bill recognisable to whoever packed the
        # parcel, and a blank number falls through to the prefixed id.
        number = owner.number.to_s if owner.respond_to?(:number)
        return number if number.present?

        prefixed_id = owner.prefixed_id.to_s if owner.respond_to?(:prefixed_id)
        return prefixed_id if prefixed_id.present?

        owner.to_s
      end

      # Anything outside the allowed alphabet is dropped rather than replaced:
      # a substituted character would be one more thing to explain when an
      # operator cannot find the number.
      def sanitize(value)
        value.to_s.gsub(/[^0-9A-Za-z_\-|*]/, '')
      end

      def sanitize_refund(value)
        value.to_s.gsub(/[^0-9A-Za-z_\-|*@]/, '')
      end
    end
  end
end
