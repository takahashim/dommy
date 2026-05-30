# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG URL §host-parsing IPv4 number form. Accepts the four
    # historical input shapes used by HTTP URLs:
    #
    #   a.b.c.d  (standard dotted-quad)
    #   a.b.c    (last segment is 16 bits)
    #   a.b      (last segment is 24 bits)
    #   a        (32-bit single number)
    #
    # Each numeric segment may be expressed in decimal, hex (`0x`
    # prefix), or octal (leading `0`). Output is always canonical
    # dotted-decimal.
    #
    # `parse(host)` returns the canonical form, or `nil` if `host`
    # doesn't look like an IPv4 number form at all.
    module Ipv4Parser
      def self.parse(host)
        return nil if host.nil? || host.empty?

        parts = host.split(".", -1)
        # WHATWG allows a single trailing empty (`1.2.3.4.`).
        parts = parts[0..-2] if parts.last == "" && parts.length > 1
        return nil if parts.empty? || parts.length > 4
        return nil if parts.any?(&:empty?)

        numbers = parts.map { |p| parse_number(p) }
        return nil if numbers.any?(&:nil?)

        # Recombine per the segment count rules.
        case numbers.length
        when 1
          n = numbers[0]
        when 2
          return nil if numbers[0] >= 256 || numbers[1] >= (1 << 24)

          n = numbers[0] * (1 << 24) + numbers[1]
        when 3
          if numbers[0] >= 256 ||
              numbers[1] >= 256 ||
              numbers[2] >= (1 << 16)
            return nil
          end

          n = numbers[0] * (1 << 24) + numbers[1] * (1 << 16) + numbers[2]
        when 4
          return nil if numbers.any? { |x| x >= 256 }

          n = numbers[0] *
            (1 << 24) +
            numbers[1] *
            (1 << 16) +
            numbers[2] *
            (1 << 8) +
            numbers[3]
        end

        return nil if n >= (1 << 32)

        [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF].join(".")
      end

      def self.parse_number(str)
        return nil if str.empty?

        radix = 10
        digits = str
        if str.length >= 2 && (str[0, 2] == "0x" || str[0, 2] == "0X")
          radix = 16
          digits = str[2..]
        elsif str.length >= 2 && str[0] == "0"
          radix = 8
          digits = str[1..]
        end

        # A bare radix prefix (`0x`, `0`) denotes the number 0.
        return 0 if digits.empty?

        valid =
          case radix
          when 16 then digits.match?(/\A[0-9a-fA-F]+\z/)
          when 8 then digits.match?(/\A[0-7]+\z/)
          else digits.match?(/\A[0-9]+\z/)
          end
        return nil unless valid

        digits.to_i(radix)
      end
    end
  end
end
