# frozen_string_literal: true

require_relative "encodings/tables"
require_relative "internal/mime_type"

module Dommy
  # The Encoding Standard's encodings: every label it knows, and a decoder for
  # each encoding that turns bytes into code points, streaming, with the
  # replacement-or-throw error mode TextDecoder exposes as `fatal`.
  #
  # Every decoder is the spec's own algorithm: UTF-8, UTF-16 and the legacy
  # single-byte encodings here, with their index tables, and the legacy
  # multi-byte ones (Big5, EUC-JP, ISO-2022-JP, Shift_JIS, EUC-KR, GBK,
  # gb18030) in encodings/legacy_multibyte, which read their indexes through
  # the Ruby encoding that matches each.
  #
  # Spec: https://encoding.spec.whatwg.org/
  module Encodings
    REPLACEMENT_CHARACTER = 0xFFFD

    # The name of the encoding `label` stands for, or nil. Only ASCII
    # whitespace around the label is ignored.
    #
    # Spec: https://encoding.spec.whatwg.org/#concept-encoding-get
    def self.get(label)
      LABELS[label.gsub(/\A[\t\n\f\r ]+|[\t\n\f\r ]+\z/, "").downcase(:ascii)]
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

    # A document's bytes as text, and the encoding they were decoded with
    # (::document_encoding), which is the document's: a caller hands both to
    # the document, so that its URLs encode a query as its bytes were.
    # `html: false` (an XML or a text document) skips the `<meta>` prescan.
    def self.decode_document(bytes, content_type, html: true)
      encoding = document_encoding(bytes, content_type, html: html)
      [decode(bytes.to_s, encoding), encoding]
    end

    # The encoding an HTML document's bytes are in: a byte-order mark's, else
    # the Content-Type's `charset`, else what a `<meta>` in the first 1024
    # bytes declares (the prescan), else UTF-8.
    #
    # Spec: https://html.spec.whatwg.org/#determining-the-character-encoding
    def self.document_encoding(bytes, content_type, html: true)
      bytes = bytes.to_s.b
      BOMS.each { |mark, name| return name if bytes.start_with?(mark) }
      label = Internal::MimeType.charset_of(content_type.to_s)
      (label && get(label)) || (html && prescan(bytes)) || "UTF-8"
    end

    META_TAG = /<meta(?=[\s\/>])([^>]*)>/i
    META_ATTRIBUTE = /([^\s="'\/>][^\s=\/>]*)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s>]+))?/
    private_constant :META_TAG, :META_ATTRIBUTE

    # HTML's "prescan a byte stream to determine its encoding", for the
    # `<meta charset>` and `<meta http-equiv=content-type content="…;
    # charset=…">` forms, outside comments, in the first 1024 bytes. A
    # declared UTF-16 is UTF-8 (the bytes are ASCII-compatible if the tag was
    # read), and x-user-defined windows-1252.
    #
    # Spec: https://html.spec.whatwg.org/#prescan-a-byte-stream-to-determine-its-encoding
    def self.prescan(source)
      head = source.to_s.b.byteslice(0, 1024).gsub(/<!--.*?(?:-->|\z)/m, "")
      head.scan(META_TAG) do |(attributes)|
        attrs = {}
        attributes.scan(META_ATTRIBUTE) { |name, value| attrs[name.downcase] ||= value.to_s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") }
        label =
          if attrs["charset"]
            attrs["charset"]
          elsif attrs["http-equiv"]&.casecmp?("content-type") && attrs["content"]
            Internal::MimeType.charset_of(attrs["content"]) || attrs["content"][/charset\s*=\s*["']?([^"';\s]+)/i, 1]
          end
        name = label && get(label)
        next unless name

        return "UTF-8" if name.start_with?("UTF-16")
        return name == "x-user-defined" ? "windows-1252" : name
      end
      nil
    end

    # The bytes `string` encodes to in the encoding named `name` (as `get`
    # returns it); a code point the encoding cannot represent is the bytes the
    # block returns for it. The legacy multi-byte encoders and the single-byte
    # ones (an index read backwards) are the spec's own; Ruby encodes the rest
    # (GBK, gb18030), and UTF-8 is the string's own bytes.
    #
    # Spec: https://encoding.spec.whatwg.org/#encode
    def self.encode(name, string, &unmappable)
      return LegacyEncoders.encode(name, string, &unmappable).pack("C*") if LegacyEncoders.handles?(name)
      return single_byte_encode(single_byte_pointers(name), string, &unmappable) if SINGLE_BYTE_INDEXES.key?(name)
      return x_user_defined_encode(string, &unmappable) if name == "x-user-defined"

      ruby = begin
        ::Encoding.find(name.to_s)
      rescue ArgumentError
        nil
      end
      return string.b if ruby.nil? || ruby == ::Encoding::UTF_8

      begin
        string.encode(ruby).b
      rescue ::Encoding::UndefinedConversionError, ::Encoding::InvalidByteSequenceError
        string.each_char.each_with_object(+"".b) do |char, out|
          out << char.encode(ruby).b
        rescue ::Encoding::UndefinedConversionError, ::Encoding::InvalidByteSequenceError
          out << unmappable.call(char.ord).pack("C*")
        end
      end
    end

    # A single-byte index read backwards, code point => byte, made once per
    # encoding.
    @single_byte_pointers = {}
    def self.single_byte_pointers(name)
      @single_byte_pointers[name] ||= SINGLE_BYTE_INDEXES[name].each_with_index.each_with_object({}) do |(code_point, pointer), map|
        map[code_point] ||= pointer + 0x80 if code_point
      end.freeze
    end
    private_class_method :single_byte_pointers

    # Spec: https://encoding.spec.whatwg.org/#single-byte-encoder
    def self.single_byte_encode(pointers, string, &unmappable)
      string.each_codepoint.each_with_object(+"".b) do |code_point, out|
        byte = code_point <= 0x7F ? code_point : pointers[code_point]
        byte ? out << byte : out << unmappable.call(code_point).pack("C*")
      end
    end
    private_class_method :single_byte_encode

    # Spec: https://encoding.spec.whatwg.org/#x-user-defined-encoder
    def self.x_user_defined_encode(string, &unmappable)
      string.each_codepoint.each_with_object(+"".b) do |code_point, out|
        if code_point <= 0x7F
          out << code_point
        elsif code_point.between?(0xF780, 0xF7FF)
          out << (code_point - 0xF780 + 0x80)
        else
          out << unmappable.call(code_point).pack("C*")
        end
      end
    end
    private_class_method :x_user_defined_encode

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
      when "ISO-2022-JP" then Iso2022JpDecoder.new(fatal)
      when "Shift_JIS" then ShiftJisDecoder.new(fatal)
      when "EUC-JP" then EucJpDecoder.new(fatal)
      when "Big5" then Big5Decoder.new(fatal)
      when "EUC-KR" then EucKrDecoder.new(fatal)
      # GBK's decoder is gb18030's.
      when "GBK", "gb18030" then Gb18030Decoder.new(fatal)
      else
        index = SINGLE_BYTE_INDEXES[name]
        return SingleByteDecoder.new(fatal, index) if index

        # `name` comes from ::get, so every spec encoding is covered above. A
        # name from anywhere else is the caller's mistake, and says so rather
        # than surfacing a Hash's KeyError.
        raise ArgumentError, "not an encoding the standard names: #{name.inspect}"
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
  end
end

require_relative "encodings/legacy_multibyte"
