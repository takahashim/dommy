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

    # encode(string) → Array<Integer> (bytes).
    # Browsers return a Uint8Array; Dommy returns the equivalent Ruby
    # byte array since there is no typed-array layer.
    def encode(input = "")
      input.to_s.encode(Encoding::UTF_8).bytes
    end

    def __js_get__(key)
      key == "encoding" ? encoding : nil
    end

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
    def initialize(label = "utf-8", _options = nil)
      @encoding = normalize_encoding(label.to_s)
    end

    def encoding
      @encoding
    end

    # decode(bytes) → String. Accepts Array<Integer> (byte values),
    # a binary String, or anything responding to to_a/bytes.
    def decode(input = nil, _options = nil)
      return "" if input.nil?

      bytes = case input
      when String
        input.b
      when Array
        input.pack("C*")
      else
        input.respond_to?(:to_a) ? input.to_a.pack("C*") : input.to_s
      end

      bytes.force_encoding(ruby_encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def __js_get__(key)
      key == "encoding" ? encoding : nil
    end

    def __js_call__(method, args)
      case method
      when "decode"
        decode(args[0], args[1])
      end
    end

    private

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
          "close" => proc { @readable.internal_close },
          "abort" => proc { |r| @readable.internal_error(r) }
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
          "close" => proc { @readable.internal_close },
          "abort" => proc { |r| @readable.internal_error(r) }
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
      end
    end
  end
end
