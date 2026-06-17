# frozen_string_literal: true

module Dommy
  # `TextEncoder` — encodes a String into UTF-8 bytes.
  # Per spec, only "utf-8" encoding is supported.
  #
  # Spec: https://encoding.spec.whatwg.org/#textencoder
  class TextEncoder
    def encoding
      "utf-8"
    end

    # encode(string) → Uint8Array (UTF-8 bytes). Lone surrogates in the input
    # have already been replaced with U+FFFD when the JS string crossed into Ruby
    # (Ruby strings can't hold them), matching the spec's USVString conversion.
    def encode(input = "")
      str = input.equal?(Bridge::UNDEFINED) ? "" : input.to_s
      Bridge::Bytes.new(str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).bytes)
    end

    def __js_get__(key)
      key == "encoding" ? encoding : Bridge::ABSENT
    end

    include Bridge::Methods
    js_methods %w[encode]
    def __js_call__(method, args)
      case method
      when "encode"
        encode(args[0])
      end
    end
  end

  # `TextDecoder` — decodes bytes into a String. Supports utf-8,
  # utf-16, utf-16le, utf-16be, iso-8859-1 (best-effort).
  #
  # Spec: https://encoding.spec.whatwg.org/#textdecoder
  class TextDecoder
    def initialize(label = "utf-8", options = nil)
      label = "utf-8" if label.nil? || label.equal?(Bridge::UNDEFINED)
      @encoding = normalize_encoding(label.to_s)
      opts = options.is_a?(Hash) ? options : {}
      @fatal = truthy?(opts["fatal"] || opts[:fatal])
      @ignore_bom = truthy?(opts["ignoreBOM"] || opts[:ignoreBOM])
    end

    attr_reader :encoding

    def fatal? = @fatal
    def ignore_bom? = @ignore_bom

    # decode(bytes, {stream}) → String. Accepts a Bytes buffer (JS ArrayBuffer /
    # TypedArray), an Array<Integer>, or a binary String. With `fatal: true` an
    # invalid sequence throws a TypeError; otherwise it is replaced with U+FFFD.
    # A leading BOM is stripped unless `ignoreBOM` was set.
    def decode(input = nil, options = nil)
      stream = options.is_a?(Hash) && truthy?(options["stream"] || options[:stream])
      bytes = extract_bytes(input)

      if @encoding == "utf-8"
        decode_utf8(bytes, stream)
      else
        # Non-UTF-8 (utf-16le/be, iso-8859-1): no streaming/exact-FFFD semantics,
        # best-effort via Ruby's transcoder.
        bytes = strip_bom(bytes) unless @ignore_bom
        raw = bytes.force_encoding(ruby_encoding)
        raise Bridge::TypeError, "decode failed" if @fatal && !raw.valid_encoding?

        raw.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end

    def __js_get__(key)
      case key
      when "encoding" then @encoding
      when "fatal" then @fatal
      when "ignoreBOM" then @ignore_bom
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[decode]
    def __js_call__(method, args)
      case method
      when "decode"
        decode(args[0], args[1])
      end
    end

    private

    def extract_bytes(input)
      return "".b if input.nil? || input.equal?(Bridge::UNDEFINED)

      case input
      when Bridge::Bytes then input.pack_bytes
      when String then input.b
      when Array then input.pack("C*")
      else input.respond_to?(:to_a) ? input.to_a.pack("C*") : input.to_s.b
      end
    end

    # WHATWG "UTF-8 decoder" — a stateful machine so streaming chunks, exact
    # U+FFFD placement, and end-of-queue flushing match the spec (Ruby's
    # transcoder replaces per-byte, which is wrong at sequence boundaries).
    # State persists on the decoder across `{stream: true}` calls.
    def decode_utf8(bytes, stream)
      @u8_needed ||= 0
      @u8_seen ||= 0
      @u8_cp ||= 0
      @u8_lower ||= 0x80
      @u8_upper ||= 0xBF

      out = []
      queue = bytes.bytes
      @u8_started = true

      until queue.empty?
        byte = queue.shift
        if @u8_needed.zero?
          if byte <= 0x7F
            out << byte
          elsif byte.between?(0xC2, 0xDF)
            @u8_needed = 1
            @u8_cp = byte & 0x1F
          elsif byte.between?(0xE0, 0xEF)
            @u8_lower = 0xA0 if byte == 0xE0
            @u8_upper = 0x9F if byte == 0xED
            @u8_needed = 2
            @u8_cp = byte & 0x0F
          elsif byte.between?(0xF0, 0xF4)
            @u8_lower = 0x90 if byte == 0xF0
            @u8_upper = 0x8F if byte == 0xF4
            @u8_needed = 3
            @u8_cp = byte & 0x07
          else
            out << utf8_error
          end
          next
        end

        unless byte.between?(@u8_lower, @u8_upper)
          # Invalid continuation: emit an error and REPROCESS this byte.
          reset_utf8_state
          out << utf8_error
          queue.unshift(byte)
          next
        end

        @u8_lower = 0x80
        @u8_upper = 0xBF
        @u8_cp = (@u8_cp << 6) | (byte & 0x3F)
        @u8_seen += 1
        next unless @u8_seen == @u8_needed

        out << @u8_cp
        reset_utf8_state
      end

      unless stream
        if @u8_needed != 0
          reset_utf8_state
          out << utf8_error
        end
      end

      # Strip a leading byte-order mark at the code-point level, not the byte
      # level: a BOM split across streaming chunks (EF BB in one decode() call,
      # BF in the next) only surfaces as a single U+FEFF once the full sequence
      # decodes, which a byte-prefix check would miss. The "BOM seen" flag
      # persists across `{stream: true}` calls and is reset on flush.
      unless @ignore_bom || @u8_bom_seen
        if out[0] == 0xFEFF
          out.shift
          @u8_bom_seen = true
        elsif !out.empty?
          @u8_bom_seen = true
        end
      end

      unless stream
        @u8_started = false
        @u8_bom_seen = false
      end

      out.pack("U*")
    end

    # In fatal mode an error throws a TypeError; otherwise it is the U+FFFD
    # replacement code point.
    def utf8_error
      raise Bridge::TypeError, "The encoded data was not valid for encoding utf-8" if @fatal

      0xFFFD
    end

    def reset_utf8_state
      @u8_needed = 0
      @u8_seen = 0
      @u8_cp = 0
      @u8_lower = 0x80
      @u8_upper = 0xBF
    end

    # JS ToBoolean for an option-bag value (false/nil/undefined/0/"" are falsy).
    def truthy?(value)
      return false if value.nil? || value == false || value == 0 || value == ""
      return false if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)

      true
    end

    # Remove a leading byte-order mark matching this decoder's encoding.
    def strip_bom(bytes)
      case @encoding
      when "utf-8"
        bytes.start_with?("\xEF\xBB\xBF".b) ? bytes.byteslice(3..) : bytes
      when "utf-16le"
        bytes.start_with?("\xFF\xFE".b) ? bytes.byteslice(2..) : bytes
      when "utf-16be"
        bytes.start_with?("\xFE\xFF".b) ? bytes.byteslice(2..) : bytes
      else
        bytes
      end
    end

    def normalize_encoding(label)
      l = label.downcase.strip
      case l
      when "utf-8", "utf8"
        "utf-8"
      when "utf-16", "utf-16le"
        "utf-16le"
      when "utf-16be"
        "utf-16be"
      when "iso-8859-1", "latin1"
        "iso-8859-1"
      else
        "utf-8"
      end
    end

    def ruby_encoding
      case @encoding
      when "utf-8"
        Encoding::UTF_8
      when "utf-16le"
        Encoding::UTF_16LE
      when "utf-16be"
        Encoding::UTF_16BE
      when "iso-8859-1"
        Encoding::ISO_8859_1
      else
        Encoding::UTF_8
      end
    end
  end

  # `TextEncoderStream` — Stream-shaped wrapper over `TextEncoder`.
  # `write(string)` flushes UTF-8 bytes downstream.
  class TextEncoderStream
    attr_reader :readable, :writable

    def initialize(window)
      encoder = TextEncoder.new
      @readable = ReadableStream.new(window)
      controller = TransformStreamDefaultController.new(@readable)

      @writable = WritableStream.new(
        window,
        {
          "write" => proc { |chunk| controller.enqueue(encoder.encode(chunk)) },
          "close" => proc { @readable.__internal_close__ },
          "abort" => proc { |r| @readable.__internal_error__(r) }
        }
      )
    end

    def encoding
      "utf-8"
    end

    def __js_get__(key)
      case key
      when "readable"
        @readable
      when "writable"
        @writable
      when "encoding"
        encoding
      else
        Bridge::ABSENT
      end
    end
  end

  # `TextDecoderStream` — Stream-shaped wrapper over `TextDecoder`.
  # `write(bytes)` flushes decoded strings downstream.
  class TextDecoderStream
    attr_reader :readable, :writable, :encoding

    def initialize(window, label = "utf-8", _options = nil)
      decoder = TextDecoder.new(label)
      @encoding = decoder.encoding
      @readable = ReadableStream.new(window)
      controller = TransformStreamDefaultController.new(@readable)

      @writable = WritableStream.new(
        window,
        {
          "write" => proc { |chunk| controller.enqueue(decoder.decode(chunk)) },
          "close" => proc { @readable.__internal_close__ },
          "abort" => proc { |r| @readable.__internal_error__(r) }
        }
      )
    end

    def __js_get__(key)
      case key
      when "readable"
        @readable
      when "writable"
        @writable
      when "encoding"
        @encoding
      else
        Bridge::ABSENT
      end
    end
  end
end
