# frozen_string_literal: true

module Dommy
  module Js
    # The wire protocol shared by every Ruby<->JS marshaller in this gem: the
    # tagged-Hash shapes that cross the boundary (a handle, a callback, an opaque
    # JS ref, a byte buffer, a tagged exception, …). Both Ruby marshallers —
    # HostBridge#wrap/#unwrap (the Proxy bridge) and WasmBridge#pack/#unpack (the
    # wasm guest bridge) — build and match these keys, so keeping them as one set
    # of constants prevents the two sides from drifting apart.
    #
    # The JS half (host_runtime.js: dehydrate/rehydrate/wasmTag/wasmDeref) mirrors
    # the SAME string literals. When changing a tag here, update host_runtime.js
    # in lockstep — these constants are the canonical names; the JS literals are
    # the mirror.
    module WireTags
      # A bridged Ruby object, referenced by its HandleTable id (becomes an ES
      # Proxy on the JS side).
      HANDLE = "__rb_handle"
      # The host object's WebIDL interface name, carried alongside its handle so
      # makeProxy can reuse a cached per-interface descriptor (prototype chain +
      # method set) instead of a `__rb_host_describe` round trip per new proxy —
      # the dominant overhead when JS traverses/builds many nodes.
      INTERFACE = "__rb_if"
      # The custom-element tag of a handle whose node is a registered custom
      # element (so makeProxy upgrades it), carried per-instance since it is the
      # one part of a describe that is NOT per-interface.
      CUSTOM_ELEMENT = "__rb_ce"
      # A live JS function that crossed into Ruby, referenced by callback id.
      CALLBACK = "__rb_callback"
      # An opaque JS value referenced by its id in the JS-side `jsRefs` table
      # (shared by the Proxy and wasm bridges). See Dommy::Bridge::JSValue.
      JS_REF = "__rb_js_ref"
      # A human-readable label captured alongside a JS ref (for #to_s/#inspect).
      JS_LABEL = "__rb_js_label"
      # Marks a JS ref that implements the EventListener interface (handleEvent).
      HANDLE_EVENT = "__rb_handle_event"
      # Marks a JS ref that implements the NodeFilter interface (acceptNode).
      ACCEPT_NODE = "__rb_accept_node"
      # The JS `undefined` value (distinct from null / Ruby nil).
      UNDEFINED = "__rb_undefined"
      # A genuinely-absent property: marshals to JS `undefined` as a value, but the
      # proxy reports it MISSING for the `in` operator (distinct from UNDEFINED,
      # which is present-but-undefined). See Dommy::Bridge::ABSENT.
      ABSENT = "__rb_absent"
      # A byte buffer crossing as a JS Uint8Array.
      BYTES = "__rb_bytes"
      # A byte buffer crossing as a bare JS ArrayBuffer.
      ARRAY_BUFFER = "__rb_arraybuffer"
      # A host-raised DOMException/TypeError/RangeError, re-thrown JS-side.
      EXCEPTION = "__rb_exception__"
      # A host-created native JS error (TypeError/RangeError) crossing as a VALUE
      # — not thrown — so e.g. a promise rejected with it has a reason that is a
      # real `instanceof TypeError`. Rehydrates to the error object itself.
      ERROR_VALUE = "__rb_error_value"
      # An arbitrary host-thrown value, re-thrown JS-side verbatim.
      THROW = "__rb_throw__"
      # A callback whose JS invocation threw (the thrown value is carried here).
      CALLBACK_THREW = "__rb_cb_threw__"
    end
  end
end
