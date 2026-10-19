require 'spec_helper'

RSpec.describe SpreeWechatPay::MerchantOrderNumber do
  # WeChat's rules, quoted: 6–32 characters, only digits, upper- and lower-case
  # letters, `_`, `-`, `|` and `*`, unique within the merchant number.
  describe '.generate' do
    it 'produces something WeChat would accept' do
      expect(described_class.generate(nil)).to satisfy { |number| described_class.valid?(number) }
    end

    it 'satisfies the rules for an owner whose number is far too long' do
      owner = double('Owner', number: 'X' * 200)

      expect(described_class.generate(owner).length).to be <= 32
    end

    it 'strips characters the alphabet does not allow' do
      owner = double('Owner', number: 'R1001/../etc')

      expect(described_class.generate(owner)).to match(described_class::CHARSET)
    end

    it 'keeps the owner number readable, so an operator can reconcile a bill' do
      owner = double('Owner', number: 'R1001')

      expect(described_class.generate(owner, suffix: 'abcd1234')).to eq('R1001-abcd1234')
    end

    # The suffix is what makes the number unique, so truncation has to eat into
    # the readable part rather than the random one.
    it 'never truncates the part that guarantees uniqueness' do
      owner = double('Owner', number: 'R' * 60)
      number = described_class.generate(owner, suffix: 'abcd1234')

      expect(number).to end_with('abcd1234')
      expect(number.length).to eq(32)
    end

    it 'still produces a valid number when the owner has none' do
      owner = double('Owner', number: nil)
      number = described_class.generate(owner)

      expect(described_class.valid?(number)).to be true
    end

    it 'does not repeat itself' do
      numbers = Array.new(50) { described_class.generate(nil) }

      expect(numbers.uniq.size).to eq(50)
    end
  end

  describe '.valid?' do
    it 'accepts the boundary lengths' do
      expect(described_class.valid?('a' * 6)).to be true
      expect(described_class.valid?('a' * 32)).to be true
    end

    it 'refuses what is too short or too long' do
      expect(described_class.valid?('a' * 5)).to be false
      expect(described_class.valid?('a' * 33)).to be false
    end

    it 'refuses a character outside the alphabet' do
      expect(described_class.valid?('R1001@2026')).to be false
    end

    it 'accepts every character WeChat allows' do
      expect(described_class.valid?('aA0_-|*aA0')).to be true
    end
  end

  # Refund numbers obey their own rules: up to 64 bytes and a wider alphabet
  # where `@` is allowed.
  describe '.generate_refund' do
    it 'produces something WeChat would accept' do
      expect(described_class.generate_refund(nil)).to satisfy { |number| described_class.valid_refund?(number) }
    end

    it 'keeps the refund readable by its prefixed id' do
      owner = double('Refund', prefixed_id: 're_86Rf07xd4z', number: nil)

      expect(described_class.generate_refund(owner, suffix: 'abcd1234')).to eq('re_86Rf07xd4z-abcd1234')
    end

    it 'stays within 64 bytes for a long owner reference' do
      owner = double('Refund', prefixed_id: 'R' * 200, number: nil)

      expect(described_class.generate_refund(owner).bytesize).to be <= 64
    end

    it 'allows the @ character the refund alphabet adds' do
      owner = double('Refund', prefixed_id: 're_@refund', number: nil)

      expect(described_class.generate_refund(owner, suffix: 'abcd1234')).to include('@')
    end
  end
end
