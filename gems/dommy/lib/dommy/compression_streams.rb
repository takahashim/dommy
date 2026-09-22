# frozen_string_literal: true

require "zlib"
require "stringio"

module Dommy
  # `CompressionStream` / `DecompressionStream` — wrap `TransformStream`
  # over Ruby's `Zlib` to gzip/deflate/raw-deflate byte chunks. Each
  # `write(chunk)` accumulates into an internal buffer; `close()`
  # finalizes and emits the compressed/decompressed bytes downstream.
  #
  # Spec: https://wicg.github.io/compression/
  class CompressionStream < TransformStream
    SUPPORTED = %w[gzip deflate deflate-raw].freeze

    def initialize(window, format)
      raise ArgumentError, "unsupported format #{format.inspect}" unless SUPPORTED.include?(format.to_s)

      buffer = +""
      compressor = build_compressor(format.to_s)
      super(window, {
        "transform" => proc { |chunk, _controller| buffer << coerce(chunk); nil },
        "flush" => proc { |controller| controller.enqueue(compressor.call(buffer)); nil }
      })
    end

    private

    def coerce(chunk)
      chunk.is_a?(Array) ? chunk.pack("C*") : chunk.to_s
    end

    def build_compressor(format)
      case format
      when "gzip"
        proc do |data|
          io = StringIO.new
          gz = Zlib::GzipWriter.new(io)
          gz.write(data)
          gz.close
          io.string.bytes
        end

      when "deflate"
        proc { |data| Zlib::Deflate.deflate(data).bytes }
      when "deflate-raw"
        proc do |data|
          z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
          out = z.deflate(data, Zlib::FINISH)
          z.close
          out.bytes
        end
      end
    end
  end

  class DecompressionStream < TransformStream
    SUPPORTED = %w[gzip deflate deflate-raw].freeze

    def initialize(window, format)
      raise ArgumentError, "unsupported format #{format.inspect}" unless SUPPORTED.include?(format.to_s)

      buffer = +""
      decompressor = build_decompressor(format.to_s)
      super(window, {
        "transform" => proc { |chunk, _controller| buffer << coerce(chunk); nil },
        "flush" => proc { |controller| controller.enqueue(decompressor.call(buffer)); nil }
      })
    end

    private

    def coerce(chunk)
      chunk.is_a?(Array) ? chunk.pack("C*") : chunk.to_s
    end

    def build_decompressor(format)
      case format
      when "gzip"
        proc do |data|
          io = StringIO.new(data)
          gz = Zlib::GzipReader.new(io)
          out = gz.read
          gz.close
          out.bytes
        end

      when "deflate"
        proc { |data| Zlib::Inflate.inflate(data).bytes }
      when "deflate-raw"
        proc do |data|
          z = Zlib::Inflate.new(-Zlib::MAX_WBITS)
          out = z.inflate(data)
          z.finish
          z.close
          out.bytes
        end
      end
    end
  end
end
