# frozen_string_literal: true

module Dommy
  module Bridge
    # The Ruby shapes a JS value takes while it is on this side: an opaque
    # reference, and the two byte buffers that cross as a typed array or a bare
    # ArrayBuffer.

    # An opaque handle to a JS-side value that Ruby only stores and hands back
    # (an AbortSignal's reason, a CustomEvent's detail). A non-plain JS object
    # (Error, class instance, …) crosses as one of these instead of being
    # flattened to a Hash, so it round-trips with IDENTITY preserved. `to_s`
    # exposes the captured JS string form for the rare Ruby consumer that needs
    # text (e.g. building a message).
    class JSValue
      attr_reader :ref

      # `stack_frames` are the value's JS stack, when the tag that crossed
      # carried one. Ruby cannot reach through a ref to read `.stack`, so an
      # error-shaped value brings its frames with it (see host_runtime.js
      # tagValue) and reporting uses them for the source position.
      attr_reader :stack_frames

      # The value's JS constructor name, when the tag carried one.
      attr_reader :js_name

      def initialize(ref, label = nil, stack_frames = nil, js_name = nil)
        @ref = ref
        @label = label
        @stack_frames = stack_frames
        @js_name = js_name
      end

      def to_s = (@label || "[object]").to_s
      def inspect = "#<Dommy::Bridge::JSValue #{to_s}>"
    end

    # A byte buffer that crosses the JS boundary as a `Uint8Array` (rather than a
    # plain Array). Wrap a host method's byte-array result in this so JS sees a
    # real typed array — e.g. `TextEncoder#encode`, `Blob#arrayBuffer`. The
    # reverse direction (a JS ArrayBuffer/TypedArray argument) arrives as a
    # `Bytes` too. It subclasses Array so plain-Array callers (and `== [..]`
    # comparisons) keep working; only the bridge treats it specially.
    class Bytes < ::Array
      def initialize(bytes = [])
        super()
        concat(coerce(bytes))
      end

      alias bytes to_a
      def pack_bytes = pack("C*")

      private

      # A String is the packed form — what #pack_bytes produces — so it unpacks
      # rather than going through Array(), which would wrap it and take `to_i`
      # of the whole thing: `Bytes.new("abc")` used to be one zero byte, with no
      # complaint, which is the shape of a round trip gone wrong.
      def coerce(bytes)
        return bytes.b.unpack("C*") if bytes.is_a?(::String)

        Array(bytes).map do |byte|
          raise ArgumentError, "not a byte: #{byte.inspect}" unless byte.respond_to?(:to_int)

          byte.to_int & 0xFF
        end
      end
    end

    # Like `Bytes`, but crosses the JS boundary as a bare `ArrayBuffer` rather
    # than a `Uint8Array` view. Use this for the spec methods whose return type
    # is `ArrayBuffer` — `Response`/`Blob`/`FileReader`/`XMLHttpRequest`'s
    # `arrayBuffer`. Subclasses `Bytes` so Ruby-level `== [..]` comparisons still
    # hold; only the bridge distinguishes it (and must check it before `Bytes`).
    class ArrayBuffer < Bytes
    end
  end
end
