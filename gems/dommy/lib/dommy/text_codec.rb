# frozen_string_literal: true

require_relative "encodings"

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

  # `TextDecoder` — decodes bytes into a String, in any encoding the Encoding
  # Standard names: UTF-8, UTF-16LE/BE, the legacy single-byte encodings from
  # the spec's own index tables, and the legacy multi-byte ones through Ruby's
  # converters (see Dommy::Encodings). An unknown label, or "replacement", is
  # a RangeError.
  #
  # Spec: https://encoding.spec.whatwg.org/#textdecoder
  class TextDecoder
    BOM_ENCODINGS = %w[UTF-8 UTF-16LE UTF-16BE].freeze
    private_constant :BOM_ENCODINGS

    def initialize(label = "utf-8", options = nil)
      label = "utf-8" if label.equal?(Bridge::UNDEFINED)
      @name = Encodings.get(label.to_s)
      if @name.nil? || @name == "replacement"
        raise Bridge::RangeError, "The given encoding is not supported: #{label.to_s.inspect}"
      end

      @encoding = @name.downcase
      opts = options.is_a?(Hash) ? options : {}
      @fatal = truthy?(opts["fatal"] || opts[:fatal])
      @ignore_bom = truthy?(opts["ignoreBOM"] || opts[:ignoreBOM])
      @decoder = nil
      @bom_seen = false
    end

    attr_reader :encoding

    def fatal? = @fatal
    def ignore_bom? = @ignore_bom

    # decode(bytes, {stream}) → String. Accepts a Bytes buffer (JS ArrayBuffer /
    # TypedArray), an Array<Integer>, or a binary String. With `fatal: true` an
    # invalid sequence throws a TypeError; otherwise it is replaced with U+FFFD.
    # A leading byte-order mark is stripped unless `ignoreBOM` was set. With
    # `stream: true` a partial sequence at the end is kept for the next call.
    #
    # Spec: https://encoding.spec.whatwg.org/#dom-textdecoder-decode
    def decode(input = nil, options = nil)
      stream = options.is_a?(Hash) && truthy?(options["stream"] || options[:stream])
      @decoder ||= Encodings.decoder_for(@name, fatal: @fatal)
      code_points = @decoder.decode(extract_bytes(input), flush: !stream)

      # The byte-order mark is dropped at the code-point level, so one split
      # across streaming chunks is still recognized, and only once per stream.
      if !@ignore_bom && !@bom_seen && BOM_ENCODINGS.include?(@name) && !code_points.empty?
        code_points.shift if code_points[0] == 0xFEFF
        @bom_seen = true
      end

      unless stream
        @decoder = nil
        @bom_seen = false
      end
      code_points.pack("U*")
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

    # JS ToBoolean for an option-bag value (false/nil/undefined/0/"" are falsy).
    def truthy?(value)
      return false if value.nil? || value == false || value == 0 || value == ""
      return false if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)

      true
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
