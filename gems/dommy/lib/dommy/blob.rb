# frozen_string_literal: true

module Dommy
  # `Blob` — opaque binary chunk with a MIME type, mirroring the
  # File API's `Blob` interface. Used by File, FormData, and any
  # code that needs to round-trip bytes through the DOM (e.g. a
  # `<input type="file">` test scenario).
  #
  # Spec: https://w3c.github.io/FileAPI/#blob-section
  class Blob
    attr_reader :size, :type

    # Construct a Blob from a list of parts. Each part can be:
    #   - String (treated as binary bytes)
    #   - Blob / File (their bytes are concatenated)
    #   - Array<Integer> (byte values, like ArrayBuffer)
    #   - anything else: coerced via to_s
    #
    # `options["type"]` sets the MIME type (lowercased per spec).
    # `window` (optional) lets the JS-facing `text()`/`arrayBuffer()` return real
    # Promises (they need a scheduler). A window-less Blob falls back to a
    # synchronous result, which `await` still handles.
    def initialize(parts = [], options = {}, window = nil)
      parts = [parts] unless parts.is_a?(Array)
      @data = collect_bytes(parts)
      @size = @data.bytesize
      raw_type = options["type"] || options[:type] || ""
      @type = raw_type.to_s.downcase
      @window = window
    end

    # Return a new Blob over a byte range of this one.
    # Negative indices are treated as offsets from the end (per spec).
    def slice(start = 0, last = @size, content_type = "")
      s = clamp_index(start.to_i, @size)
      e = clamp_index(last.to_i, @size)
      e = s if e < s
      Blob.new([@data.byteslice(s, e - s) || ""], {"type" => content_type.to_s}, @window)
    end

    # Read the bytes as UTF-8 text. The DOM spec returns a Promise,
    # but Dommy is synchronous, so callers can use the result directly.
    def text
      @data.dup.force_encoding(Encoding::UTF_8)
    end

    # Read the bytes as a real ArrayBuffer (the spec return type, wrapped so it
    # crosses the JS boundary as a bare ArrayBuffer rather than an Array/typed
    # array). The DOM spec returns a Promise<ArrayBuffer>; Dommy is synchronous.
    def array_buffer
      Bridge::ArrayBuffer.new(@data.bytes)
    end

    # Raw binary bytes (Ruby ASCII-8BIT string). Used by FormData /
    # fetch when serializing multipart bodies.
    def __dommy_bytes__
      @data
    end

    def __js_get__(key)
      case key
      when "size"
        @size
      when "type"
        @type
      end
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    # File < Blob inherits these (it adds only properties).
    include Bridge::Methods
    js_methods %w[slice text arrayBuffer]
    def __js_call__(method, args)
      case method
      when "slice"
        slice(args[0] || 0, args[1] || @size, args[2] || "")
      when "text"
        # WHATWG: Blob.text() returns a Promise<string>.
        promise_or_value(text)
      when "arrayBuffer"
        # WHATWG: Blob.arrayBuffer() returns a Promise<ArrayBuffer>.
        promise_or_value(array_buffer)
      end
    end

    private

    # Wrap a consumed value in a resolved Promise when a window is available;
    # otherwise return it directly (a window-less Blob — `await` copes either way).
    def promise_or_value(value)
      @window ? PromiseValue.resolve(@window, value) : value
    end

    def collect_bytes(parts)
      buf = String.new(encoding: Encoding::ASCII_8BIT)
      parts.each do |part|
        case part
        when Blob
          buf << part.__dommy_bytes__
        when String
          buf << part.dup.force_encoding(Encoding::ASCII_8BIT)
        when Array
          buf << part.pack("C*")
        else
          buf << part.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
        end
      end

      buf
    end

    def clamp_index(idx, length)
      idx = length + idx if idx.negative?
      idx.clamp(0, length)
    end
  end

  # `File` — Blob with a filename and an optional last-modified
  # timestamp. Returned from `<input type="file">` / drag-and-drop,
  # and accepted by FormData.
  #
  # Spec: https://w3c.github.io/FileAPI/#file-section
  class File < Blob
    attr_reader :name, :last_modified

    def initialize(parts, name, options = {}, window = nil)
      super(parts, options, window)
      @name = name.to_s
      raw_lm = options["lastModified"] || options[:lastModified]
      @last_modified = (raw_lm || (Time.now.to_f * 1000)).to_i
    end

    def __js_get__(key)
      case key
      when "name"
        @name
      when "lastModified"
        @last_modified
      else
        super
      end
    end
  end

  # `FileList` — immutable, ordered collection of File objects.
  # Returned by `<input type="file">#files` and DataTransfer#files.
  #
  # Spec: https://w3c.github.io/FileAPI/#filelist-section
  class FileList
    include Enumerable

    def initialize(files = [])
      @files = files.to_a.freeze
    end

    def length
      @files.length
    end

    alias size length

    def item(index)
      @files[index.to_i]
    end

    def [](index)
      item(index)
    end

    def each(&block)
      @files.each(&block)
      self
    end

    def empty?
      @files.empty?
    end

    def to_a
      @files.dup
    end

    def __js_get__(key)
      case key
      when "length"
        length
      else
        item(key.to_i) if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
      end
    end

    include Bridge::Methods
    js_methods %w[item]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      end
    end
  end
end
