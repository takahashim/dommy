# frozen_string_literal: true

module Dommy
  module Encodings
    # The legacy multi-byte decoders (Shift_JIS, EUC-JP, ISO-2022-JP, Big5,
    # EUC-KR, gb18030 — GBK's decoder is gb18030's), from the Encoding
    # Standard's handlers: which byte a broken sequence gives back to the
    # stream, and so how many U+FFFD it yields and what follows them, are the
    # algorithm's. Only the index lookup is Ruby's: a pointer is turned back
    # into the bytes that encode it, and Ruby's converter for the encoding whose
    # table matches the spec's index decodes them.
    #
    # Spec: https://encoding.spec.whatwg.org/#legacy-multi-byte-chinese-(simplified)-encodings
    class HandlerDecoder < Decoder
      # Run the handler over `bytes`, then over end-of-queue when `flush`.
      # The handler takes the byte (nil for end-of-queue), the queue it may
      # restore bytes to, and the output, and returns :finished at the end.
      def decode(bytes, flush:)
        out = []
        queue = bytes.bytes
        loop do
          if queue.empty?
            break unless flush
            break if handle(nil, queue, out) == :finished && queue.empty?
          else
            handle(queue.shift, queue, out)
          end
        end
        out
      end

      private

      def ascii?(byte) = byte && byte <= 0x7F

      # The code point Ruby's `encoding` decodes `bytes` to, or nil when they
      # decode to nothing (or to more than one code point).
      def self.lookup(encoding, bytes)
        text = bytes.pack("C*").force_encoding(encoding).encode(::Encoding::UTF_8)
        text.length == 1 ? text.ord : nil
      rescue ::EncodingError
        nil
      end
    end

    # The spec's indexes, each read through the Ruby encoding whose mapping
    # it is, and remembered.
    module LegacyIndexes
      CACHES = Hash.new { |h, k| h[k] = {} }
      private_constant :CACHES

      module_function

      def cached(name, pointer)
        cache = CACHES[name]
        return cache[pointer] if cache.key?(pointer)

        cache[pointer] = yield
      end

      # index jis0208 — JIS X 0208 with the NEC and IBM extensions, which is
      # Windows-31J: a pointer is its Shift_JIS byte pair.
      def jis0208(pointer)
        cached(:jis0208, pointer) do
          leading, trailing = pointer.divmod(188)
          bytes = [leading + (leading < 0x1F ? 0x81 : 0xC1), trailing + (trailing < 0x3F ? 0x40 : 0x41)]
          HandlerDecoder.lookup(::Encoding::Windows_31J, bytes)
        end
      end

      # index jis0212, through EUC-JP's three-byte form.
      def jis0212(pointer)
        cached(:jis0212, pointer) do
          leading, trailing = pointer.divmod(94)
          HandlerDecoder.lookup(::Encoding::EUC_JP, [0x8F, leading + 0xA1, trailing + 0xA1])
        end
      end

      # index Big5 (HKSCS).
      def big5(pointer)
        cached(:big5, pointer) do
          leading, trailing = pointer.divmod(157)
          bytes = [leading + 0x81, trailing + (trailing < 0x3F ? 0x40 : 0x62)]
          HandlerDecoder.lookup(::Encoding::Big5_HKSCS, bytes)
        end
      end

      # index EUC-KR (Windows-949).
      def euc_kr(pointer)
        cached(:euc_kr, pointer) do
          leading, trailing = pointer.divmod(190)
          HandlerDecoder.lookup(::Encoding::CP949, [leading + 0x81, trailing + 0x41])
        end
      end

      # Where index gb18030 parts from Ruby's GB18030-2000 table: GB18030-2005
      # gave 0xA8BC its character, and GB18030-2022 gave real code points to
      # bytes 2000 mapped to the Private Use Area. Keyed by byte pair.
      GB18030_REVISIONS = {
        [0xA8, 0xBC] => 0x1E3F,
        [0xA6, 0xD9] => 0xFE10, [0xA6, 0xDA] => 0xFE12, [0xA6, 0xDB] => 0xFE11, [0xA6, 0xDC] => 0xFE13,
        [0xA6, 0xDD] => 0xFE14, [0xA6, 0xDE] => 0xFE15, [0xA6, 0xDF] => 0xFE16, [0xA6, 0xEC] => 0xFE17,
        [0xA6, 0xED] => 0xFE18, [0xA6, 0xF3] => 0xFE19,
        [0xFE, 0x59] => 0x9FB4, [0xFE, 0x61] => 0x9FB5, [0xFE, 0x66] => 0x9FB6, [0xFE, 0x67] => 0x9FB7,
        [0xFE, 0x6D] => 0x9FB8, [0xFE, 0x7E] => 0x9FB9, [0xFE, 0x90] => 0x9FBA, [0xFE, 0xA0] => 0x9FBB
      }.freeze
      private_constant :GB18030_REVISIONS

      # index gb18030, the two-byte part.
      def gb18030(pointer)
        cached(:gb18030, pointer) do
          leading, trailing = pointer.divmod(190)
          bytes = [leading + 0x81, trailing + (trailing < 0x3F ? 0x40 : 0x41)]
          GB18030_REVISIONS.fetch(bytes) { HandlerDecoder.lookup(::Encoding::GB18030, bytes) }
        end
      end

      # The index gb18030 ranges code point for a four-byte pointer.
      def gb18030_ranges(pointer)
        return nil if (pointer > 39_419 && pointer < 189_000) || pointer > 1_237_575
        return 0xE7C7 if pointer == 7457

        cached(:gb18030_ranges, pointer) do
          first, rest = pointer.divmod(12_600)
          second, rest = rest.divmod(1260)
          third, fourth = rest.divmod(10)
          HandlerDecoder.lookup(::Encoding::GB18030, [first + 0x81, second + 0x30, third + 0x81, fourth + 0x30])
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#shift_jis-decoder
    class ShiftJisDecoder < HandlerDecoder
      def initialize(fatal)
        super
        @leading = 0x00
      end

      private

      def handle(byte, queue, out)
        if byte.nil?
          return :finished if @leading.zero?

          @leading = 0x00
          return out << replacement!
        end

        unless @leading.zero?
          leading = @leading
          @leading = 0x00
          pointer = nil
          offset = byte < 0x7F ? 0x40 : 0x41
          leading_offset = leading < 0xA0 ? 0x81 : 0xC1
          pointer = (leading - leading_offset) * 188 + byte - offset if byte.between?(0x40, 0x7E) || byte.between?(0x80, 0xFC)
          # Windows' end-user-defined characters, as the Private Use Area.
          return out << (0xE000 - 8836 + pointer) if pointer&.between?(8836, 10_715)

          code_point = pointer && LegacyIndexes.jis0208(pointer)
          return out << code_point if code_point

          queue.unshift(byte) if ascii?(byte)
          return out << replacement!
        end

        if ascii?(byte) || byte == 0x80
          out << byte
        elsif byte.between?(0xA1, 0xDF)
          out << (0xFF61 - 0xA1 + byte)
        elsif byte.between?(0x81, 0x9F) || byte.between?(0xE0, 0xFC)
          @leading = byte
        else
          out << replacement!
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#euc-jp-decoder
    class EucJpDecoder < HandlerDecoder
      def initialize(fatal)
        super
        @leading = 0x00
        @jis0212 = false
      end

      private

      def handle(byte, queue, out)
        if byte.nil?
          return :finished if @leading.zero?

          @leading = 0x00
          return out << replacement!
        end

        if @leading == 0x8E && byte.between?(0xA1, 0xDF)
          @leading = 0x00
          return out << (0xFF61 - 0xA1 + byte)
        end
        if @leading == 0x8F && byte.between?(0xA1, 0xFE)
          @jis0212 = true
          return @leading = byte
        end

        unless @leading.zero?
          leading = @leading
          @leading = 0x00
          code_point = nil
          if leading.between?(0xA1, 0xFE) && byte.between?(0xA1, 0xFE)
            pointer = (leading - 0xA1) * 94 + byte - 0xA1
            code_point = @jis0212 ? LegacyIndexes.jis0212(pointer) : LegacyIndexes.jis0208(pointer)
          end
          @jis0212 = false
          return out << code_point if code_point

          queue.unshift(byte) if ascii?(byte)
          return out << replacement!
        end

        if ascii?(byte)
          out << byte
        elsif byte == 0x8E || byte == 0x8F || byte.between?(0xA1, 0xFE)
          @leading = byte
        else
          out << replacement!
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#iso-2022-jp-decoder
    class Iso2022JpDecoder < HandlerDecoder
      def initialize(fatal)
        super
        @state = :ascii
        @output_state = :ascii
        @leading = 0x00
        @output = false
      end

      private

      def handle(byte, queue, out)
        case @state
        when :ascii, :roman, :katakana, :leading_byte
          return @state = :escape_start if byte == 0x1B
          return :finished if byte.nil?

          @output = false
          single_state(byte, out)
        when :trailing_byte
          if byte == 0x1B
            @state = :escape_start
            return out << replacement!
          end
          @state = :leading_byte
          return out << replacement! unless byte&.between?(0x21, 0x7E)

          out << (LegacyIndexes.jis0208((@leading - 0x21) * 94 + byte - 0x21) || replacement!)
        when :escape_start
          if byte == 0x24 || byte == 0x28
            @leading = byte
            return @state = :escape
          end
          queue.unshift(byte) unless byte.nil?
          @output = false
          @state = @output_state
          out << replacement!
        when :escape
          escape(byte, queue, out)
        end
      end

      def single_state(byte, out)
        case @state
        when :ascii
          out << (byte <= 0x7F && byte != 0x0E && byte != 0x0F ? byte : replacement!)
        when :roman
          out << case byte
                 when 0x5C then 0xA5
                 when 0x7E then 0x203E
                 else byte <= 0x7F && byte != 0x0E && byte != 0x0F ? byte : replacement!
                 end
        when :katakana
          out << (byte.between?(0x21, 0x5F) ? 0xFF61 - 0x21 + byte : replacement!)
        when :leading_byte
          return out << replacement! unless byte.between?(0x21, 0x7E)

          @leading = byte
          @state = :trailing_byte
        end
      end

      def escape(byte, queue, out)
        leading = @leading
        @leading = 0x00
        state =
          if leading == 0x28
            {0x42 => :ascii, 0x4A => :roman, 0x49 => :katakana}[byte]
          elsif leading == 0x24 && (byte == 0x40 || byte == 0x42)
            :leading_byte
          end
        if state
          @state = @output_state = state
          output = @output
          @output = true
          # Two escapes in a row with nothing between them are an error.
          return output ? out << replacement! : nil
        end
        byte.nil? ? queue.unshift(leading) : queue.unshift(leading, byte)
        @output = false
        @state = @output_state
        out << replacement!
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#big5-decoder
    class Big5Decoder < HandlerDecoder
      # Pointers whose index entry is two code points.
      PAIRS = {1133 => [0x00CA, 0x0304], 1135 => [0x00CA, 0x030C], 1164 => [0x00EA, 0x0304], 1166 => [0x00EA, 0x030C]}.freeze

      def initialize(fatal)
        super
        @leading = 0x00
      end

      private

      def handle(byte, queue, out)
        if byte.nil?
          return :finished if @leading.zero?

          @leading = 0x00
          return out << replacement!
        end

        unless @leading.zero?
          leading = @leading
          @leading = 0x00
          offset = byte < 0x7F ? 0x40 : 0x62
          pointer = (leading - 0x81) * 157 + (byte - offset) if byte.between?(0x40, 0x7E) || byte.between?(0xA1, 0xFE)
          return out.concat(PAIRS[pointer]) if PAIRS.key?(pointer)

          code_point = pointer && LegacyIndexes.big5(pointer)
          return out << code_point if code_point

          queue.unshift(byte) if ascii?(byte)
          return out << replacement!
        end

        if ascii?(byte)
          out << byte
        elsif byte.between?(0x81, 0xFE)
          @leading = byte
        else
          out << replacement!
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#euc-kr-decoder
    class EucKrDecoder < HandlerDecoder
      def initialize(fatal)
        super
        @leading = 0x00
      end

      private

      def handle(byte, queue, out)
        if byte.nil?
          return :finished if @leading.zero?

          @leading = 0x00
          return out << replacement!
        end

        unless @leading.zero?
          leading = @leading
          @leading = 0x00
          pointer = (leading - 0x81) * 190 + (byte - 0x41) if byte.between?(0x41, 0xFE)
          code_point = pointer && LegacyIndexes.euc_kr(pointer)
          return out << code_point if code_point

          queue.unshift(byte) if ascii?(byte)
          return out << replacement!
        end

        if ascii?(byte)
          out << byte
        elsif byte.between?(0x81, 0xFE)
          @leading = byte
        else
          out << replacement!
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#gb18030-decoder
    class Gb18030Decoder < HandlerDecoder
      def initialize(fatal)
        super
        @first = @second = @third = 0x00
      end

      private

      def handle(byte, queue, out)
        if byte.nil?
          return :finished if @first.zero? && @second.zero? && @third.zero?

          @first = @second = @third = 0x00
          return out << replacement!
        end

        unless @third.zero?
          unless byte.between?(0x30, 0x39)
            queue.unshift(@second, @third, byte)
            @first = @second = @third = 0x00
            return out << replacement!
          end
          pointer = ((@first - 0x81) * 12_600) + ((@second - 0x30) * 1260) + ((@third - 0x81) * 10) + byte - 0x30
          @first = @second = @third = 0x00
          return out << (LegacyIndexes.gb18030_ranges(pointer) || replacement!)
        end

        unless @second.zero?
          return @third = byte if byte.between?(0x81, 0xFE)

          queue.unshift(@second, byte)
          @first = @second = 0x00
          return out << replacement!
        end

        unless @first.zero?
          return @second = byte if byte.between?(0x30, 0x39)

          leading = @first
          @first = 0x00
          offset = byte < 0x7F ? 0x40 : 0x41
          pointer = (leading - 0x81) * 190 + (byte - offset) if byte.between?(0x40, 0x7E) || byte.between?(0x80, 0xFE)
          code_point = pointer && LegacyIndexes.gb18030(pointer)
          return out << code_point if code_point

          queue.unshift(byte) if ascii?(byte)
          return out << replacement!
        end

        if ascii?(byte)
          out << byte
        elsif byte == 0x80
          out << 0x20AC
        elsif byte.between?(0x81, 0xFE)
          @first = byte
        else
          out << replacement!
        end
      end
    end
  end
end
