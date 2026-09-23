# frozen_string_literal: true

require_relative "encodings/tables"
require_relative "internal/mime_type"

module Dommy
  # The Encoding Standard's encodings: every label it knows, and a decoder for
  # each encoding that turns bytes into code points, streaming, with the
  # replacement-or-throw error mode TextDecoder exposes as `fatal`.
  #
  # UTF-8, UTF-16 and the legacy single-byte encodings are decoded here, from
  # the spec's own algorithms and index tables. The legacy multi-byte
  # encodings (Big5, EUC-JP, ISO-2022-JP, Shift_JIS, EUC-KR, GBK, gb18030) go
  # through Ruby's converters for the encoding closest to the spec's index,
  # which differ from it in a few code points and in how many U+FFFD a broken
  # sequence yields.
  #
  # Spec: https://encoding.spec.whatwg.org/
  module Encodings
    # The Ruby encoding whose mapping is closest to the spec's index for each
    # legacy multi-byte encoding.
    RUBY_ENCODINGS = {
      "Big5" => "Big5-HKSCS",
      "EUC-JP" => "EUC-JP",
      "ISO-2022-JP" => "ISO-2022-JP",
      "Shift_JIS" => "Windows-31J",
      "EUC-KR" => "CP949",
      "GBK" => "GBK",
      "gb18030" => "GB18030"
    }.freeze

    REPLACEMENT_CHARACTER = 0xFFFD

    # The name of the encoding `label` stands for, or nil. Only ASCII
    # whitespace around the label is ignored.
    #
    # Spec: https://encoding.spec.whatwg.org/#concept-encoding-get
    def self.get(label)
      LABELS[label.gsub(/\A[\t\n\f\r ]+|[\t\n\f\r ]+\z/, "").downcase]
    end

    # The byte-order marks that name their own encoding, longest first.
    #
    # Spec: https://encoding.spec.whatwg.org/#decode
    BOMS = [
      ["\xEF\xBB\xBF".b, "UTF-8"],
      ["\xFE\xFF".b, "UTF-16BE"],
      ["\xFF\xFE".b, "UTF-16LE"]
    ].freeze

    # Bytes to a String in `fallback` (an encoding name), unless they start
    # with a byte-order mark, which names the encoding itself and is dropped.
    # Errors are U+FFFD.
    #
    # Spec: https://encoding.spec.whatwg.org/#decode
    def self.decode(bytes, fallback = "UTF-8")
      bytes = bytes.b
      name = fallback
      BOMS.each do |mark, marked_name|
        next unless bytes.start_with?(mark)

        name = marked_name
        bytes = bytes.byteslice(mark.bytesize..)
        break
      end

      valid_utf8(bytes, name) || decoder_for(name).decode(bytes, flush: true).pack("U*")
    end

    # Already-valid UTF-8 needs no decoding: the spec's decoder would walk it
    # byte by byte and rebuild it code point by code point, which measures ~40x
    # the cost of asking Ruby, on the whole-buffer path an XHR response takes.
    #
    # Only when the bytes are VALID, because that is where the two agree
    # exactly. How many U+FFFD a broken sequence yields is the decoder's to say
    # — Ruby's `scrub` does not always answer the same — so anything invalid
    # goes the long way.
    def self.valid_utf8(bytes, name)
      return nil unless name == "UTF-8"

      text = bytes.dup.force_encoding(::Encoding::UTF_8)
      text if text.valid_encoding?
    end
    private_class_method :valid_utf8

    # A fresh decoder for the encoding named `name` (as `get` returns it).
    def self.decoder_for(name, fatal: false)
      case name
      when "UTF-8" then Utf8Decoder.new(fatal)
      when "UTF-16LE" then Utf16Decoder.new(fatal, big_endian: false)
      when "UTF-16BE" then Utf16Decoder.new(fatal, big_endian: true)
      when "x-user-defined" then XUserDefinedDecoder.new(fatal)
      when "replacement" then ReplacementDecoder.new(fatal)
      else
        index = SINGLE_BYTE_INDEXES[name]
        return SingleByteDecoder.new(fatal, index) if index

        ruby_encoding = RUBY_ENCODINGS[name]
        # `name` comes from ::get, so every spec encoding is covered above. A
        # name from anywhere else is the caller's mistake, and says so rather
        # than surfacing a Hash's KeyError.
        raise ArgumentError, "not an encoding the standard names: #{name.inspect}" unless ruby_encoding

        ConverterDecoder.new(fatal, ruby_encoding)
      end
    end

    # What every decoder shares: `decode(bytes, flush:)` takes a binary String
    # and returns the code points it yields, keeping whatever partial sequence
    # is left over for the next call unless `flush` is true. An error is
    # U+FFFD, or a TypeError in fatal mode.
    class Decoder
      def initialize(fatal)
        @fatal = fatal
      end

      private

      # The code point an error yields — or, in fatal mode, no code point at
      # all, because it throws. Named for both outcomes: the callers append the
      # result (`out << replacement!`), and the `!` is the warning that control
      # may not come back.
      def replacement!
        raise Bridge::TypeError, "The encoded data was not valid" if @fatal

        REPLACEMENT_CHARACTER
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#utf-8-decoder
    class Utf8Decoder < Decoder
      def initialize(fatal)
        super
        reset
      end

      def decode(bytes, flush:)
        out = []
        queue = bytes.bytes
        until queue.empty?
          byte = queue.shift
          if @needed.zero?
            if byte <= 0x7F
              out << byte
            elsif byte.between?(0xC2, 0xDF)
              @needed = 1
              @code_point = byte & 0x1F
            elsif byte.between?(0xE0, 0xEF)
              @lower = 0xA0 if byte == 0xE0
              @upper = 0x9F if byte == 0xED
              @needed = 2
              @code_point = byte & 0x0F
            elsif byte.between?(0xF0, 0xF4)
              @lower = 0x90 if byte == 0xF0
              @upper = 0x8F if byte == 0xF4
              @needed = 3
              @code_point = byte & 0x07
            else
              out << replacement!
            end
            next
          end

          unless byte.between?(@lower, @upper)
            # Not a continuation byte: an error, and the byte is read again.
            reset
            out << replacement!
            queue.unshift(byte)
            next
          end

          @lower = 0x80
          @upper = 0xBF
          @code_point = (@code_point << 6) | (byte & 0x3F)
          @seen += 1
          next unless @seen == @needed

          out << @code_point
          reset
        end

        if flush && @needed != 0
          reset
          out << replacement!
        end
        out
      end

      private

      def reset
        @needed = 0
        @seen = 0
        @code_point = 0
        @lower = 0x80
        @upper = 0xBF
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#shared-utf-16-decoder
    class Utf16Decoder < Decoder
      def initialize(fatal, big_endian:)
        super(fatal)
        @big_endian = big_endian
        @lead_byte = nil
        @lead_surrogate = nil
      end

      def decode(bytes, flush:)
        out = []
        bytes.each_byte do |byte|
          if @lead_byte.nil?
            @lead_byte = byte
            next
          end

          code_unit = @big_endian ? ((@lead_byte << 8) + byte) : ((byte << 8) + @lead_byte)
          @lead_byte = nil

          if @lead_surrogate
            lead_surrogate = @lead_surrogate
            @lead_surrogate = nil
            if code_unit.between?(0xDC00, 0xDFFF)
              out << (0x10000 + ((lead_surrogate - 0xD800) << 10) + (code_unit - 0xDC00))
              next
            end
            # The lead surrogate had no trail: an error, and the code unit's
            # bytes are read again.
            out << replacement!
            out.concat(decode_code_unit(code_unit))
            next
          end

          out.concat(decode_code_unit(code_unit))
        end

        if flush && (@lead_byte || @lead_surrogate)
          @lead_byte = nil
          @lead_surrogate = nil
          out << replacement!
        end
        out
      end

      private

      def decode_code_unit(code_unit)
        if code_unit.between?(0xD800, 0xDBFF)
          @lead_surrogate = code_unit
          []
        elsif code_unit.between?(0xDC00, 0xDFFF)
          [replacement!]
        else
          [code_unit]
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#single-byte-decoder
    class SingleByteDecoder < Decoder
      def initialize(fatal, index)
        super(fatal)
        @index = index
      end

      def decode(bytes, flush:)
        bytes.each_byte.map do |byte|
          if byte <= 0x7F
            byte
          else
            @index[byte - 0x80] || replacement!
          end
        end
      end
    end

    # Spec: https://encoding.spec.whatwg.org/#x-user-defined-decoder
    class XUserDefinedDecoder < Decoder
      def decode(bytes, flush:)
        bytes.each_byte.map { |byte| byte <= 0x7F ? byte : 0xF780 + byte - 0x80 }
      end
    end

    # The whole stream is one error, reported once.
    #
    # Spec: https://encoding.spec.whatwg.org/#replacement-decoder
    class ReplacementDecoder < Decoder
      def initialize(fatal)
        super
        @reported = false
      end

      def decode(bytes, flush:)
        return [] if bytes.empty? || @reported

        @reported = true
        [replacement!]
      end
    end

    # A legacy multi-byte encoding, through Ruby's converter. Partial input is
    # held between calls; at a flush what is left over is an error.
    class ConverterDecoder < Decoder
      def initialize(fatal, ruby_encoding)
        super(fatal)
        options = fatal ? {} : {invalid: :replace, undef: :replace, replace: "\uFFFD"}
        @converter = ::Encoding::Converter.new(ruby_encoding, "UTF-8", **options)
      end

      def decode(bytes, flush:)
        output = +""
        result = @converter.primitive_convert(bytes.dup, output, nil, nil, partial_input: !flush)
        code_points = output.codepoints
        case result
        when :finished, :source_buffer_empty
          code_points
        when :incomplete_input, :invalid_byte_sequence, :undefined_conversion
          # Only reached in fatal mode, or by an incomplete sequence at a
          # flush; either way the stream is over.
          code_points << replacement!
        else
          # :destination_buffer_full and :after_output need a byte limit or an
          # output filter to occur, and this call passes neither. Reaching here
          # would mean the converter contract changed under us.
          raise "unexpected Encoding::Converter result: #{result.inspect}"
        end
      end
    end
  end
end
