# frozen_string_literal: true

module Dommy
  module Internal
    # RFC 3492 Punycode encoder / decoder. Used by `Internal::IDNA` to
    # turn IDN labels (e.g. `日本`) into ASCII (`wgv71a`) before they
    # reach Ruby's `URI` parser, which rejects non-ASCII hosts.
    #
    # `encode` / `decode` produce / consume the bare Punycode form
    # (no `xn--` prefix). The IDNA layer is responsible for adding /
    # stripping the prefix.
    #
    # Spec: https://datatracker.ietf.org/doc/html/rfc3492
    module Punycode
      BASE = 36
      TMIN = 1
      TMAX = 26
      SKEW = 38
      DAMP = 700
      INITIAL_BIAS = 72
      INITIAL_N = 0x80
      DELIMITER = "-"

      class Error < StandardError
      end

      # Encode a Unicode label into bare Punycode (no `xn--` prefix).
      # Returns the input unchanged if it contains only ASCII —
      # callers can detect "pure ASCII pass-through" via the absence
      # of any extended-code-point handling.
      def self.encode(input)
        codepoints = input.to_s.unpack("U*")
        output = +""

        # Step 1: copy basic (ASCII < 0x80) code points to output.
        basic = codepoints.select { |c| c < INITIAL_N }
        output << basic.pack("U*")
        h = b = basic.length

        # RFC 3492 §6.3: append a delimiter whenever there are basic
        # code points, even if no extended encoding follows. The
        # decoder relies on the delimiter to know where the basic
        # section ends.
        output << DELIMITER if b.positive?

        n = INITIAL_N
        delta = 0
        bias = INITIAL_BIAS

        while h < codepoints.length
          # Find the minimum code point >= n in the input.
          m = codepoints.select { |c| c >= n }.min
          raise Error, "punycode overflow" if (m - n) > (((2 ** 31) - 1 - delta) / (h + 1))

          delta += (m - n) * (h + 1)
          n = m

          codepoints.each do |c|
            if c < n
              delta += 1
              raise Error, "punycode overflow" if delta > ((2 ** 31) - 1)
            elsif c == n
              q = delta
              k = BASE
              loop do
                t = threshold(k, bias)
                break if q < t

                digit = t + ((q - t) % (BASE - t))
                output << digit_to_char(digit)
                q = (q - t) / (BASE - t)
                k += BASE
              end

              output << digit_to_char(q)
              bias = adapt(delta, h + 1, h == b)
              delta = 0
              h += 1
            end
          end

          delta += 1
          n += 1
        end

        output
      end

      # Decode a bare Punycode string back to Unicode. Inverse of
      # `encode`. Raises `Error` on malformed input.
      def self.decode(input)
        str = input.to_s
        output = []

        # The last delimiter splits basic code points from the
        # extended portion. If there is no delimiter, the whole input
        # is the extended portion.
        idx = str.rindex(DELIMITER)
        if idx
          str[0...idx].each_char do |ch|
            cp = ch.ord
            raise Error, "non-basic code point in basic section" if cp >= INITIAL_N

            output << cp
          end

          extended = str[(idx + 1)..]
        else
          extended = str
        end

        n = INITIAL_N
        i = 0
        bias = INITIAL_BIAS
        pos = 0
        ext_chars = extended.each_char.to_a

        while pos < ext_chars.length
          oldi = i
          w = 1
          k = BASE

          loop do
            raise Error, "truncated punycode" if pos >= ext_chars.length

            digit = char_to_digit(ext_chars[pos])
            pos += 1
            raise Error, "punycode overflow" if digit > (((2 ** 31) - 1 - i) / w)

            i += digit * w
            t = threshold(k, bias)
            break if digit < t

            raise Error, "punycode overflow" if w > (((2 ** 31) - 1) / (BASE - t))

            w *= (BASE - t)
            k += BASE
          end

          bias = adapt(i - oldi, output.length + 1, oldi.zero?)
          n += i / (output.length + 1)
          raise Error, "punycode overflow" if n > ((2 ** 31) - 1)

          i %= (output.length + 1)
          output.insert(i, n)
          i += 1
        end

        output.pack("U*")
      end

      # --- internals ---------------------------------------------------

      # RFC 3492 §6.1
      def self.adapt(delta, numpoints, firsttime)
        delta = firsttime ? delta / DAMP : delta / 2
        delta += delta / numpoints

        k = 0
        while delta > ((BASE - TMIN) * TMAX) / 2
          delta /= (BASE - TMIN)
          k += BASE
        end

        k + (((BASE - TMIN + 1) * delta) / (delta + SKEW))
      end

      def self.threshold(k, bias)
        if k <= bias
          TMIN
        elsif k >= bias + TMAX
          TMAX
        else
          k - bias
        end
      end

      # Punycode digits: 0..25 → 'a'..'z'; 26..35 → '0'..'9'.
      def self.digit_to_char(d)
        if d < 26
          ("a".ord + d).chr
        else
          ("0".ord + d - 26).chr
        end
      end

      def self.char_to_digit(ch)
        cp = ch.ord
        case cp
        when ("a".ord)..("z".ord)
          cp - "a".ord
        when ("A".ord)..("Z".ord)
          cp - "A".ord
        when ("0".ord)..("9".ord)
          cp - "0".ord + 26
        else
          raise Error, "invalid punycode digit: #{ch.inspect}"
        end
      end
    end
  end
end
