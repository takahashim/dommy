# frozen_string_literal: true

module Dommy
  module Js
    # The Ruby<->JS value marshaller + cross-boundary identity tables. Given a
    # `bridge` (used only to back the live-callback adapters), it converts Ruby
    # values to the WireTags-tagged shapes the JS side proxies (#wrap) and
    # rebuilds tagged JS values back into Ruby (#unwrap), and owns the handle /
    # callback / listener / filter caches that keep identity stable across the
    # boundary.
    #
    # Extracted from HostBridge so the marshalling concern is separate from the
    # host-function ABI registration — and so a second bridge (a future wasm
    # guest bridge, see WireTags) can reuse the exact same logic rather than
    # re-deriving the tag shapes. Engine-agnostic.
    class Marshaller
      # A JS `stack` string as backtrace lines, or nil when there is none.
      def self.stack_frames(stack)
        return nil if stack.nil?

        stack.to_s.lines.map(&:strip).reject(&:empty?)
      end

      def initialize(bridge)
        @bridge = bridge
        @handles = HandleTable.new
        @callback_objects = {}
        @listener_objects = {}
        @filter_objects = {}
      end

      # ---- handle table (cross-boundary object identity) ----

      def register(obj) = @handles.register(obj)
      def rebind(old, new) = @handles.rebind(old, new)
      def host(handle) = @handles.fetch(handle)
      def release(handle) = @handles.release(handle)
      def size = @handles.size

      # ---- value marshalling ----

      # Ruby -> JS: tag bridge-able objects so the JS side can proxy them.
      # Recurses Array and Hash so nested DOM nodes are tagged too (symmetric
      # with #unwrap).
      def wrap(value)
        # A `__js_call__` may return the UNDEFINED sentinel for a void op; marshal
        # it so the JS side yields `undefined` rather than `null`.
        if value.equal?(Dommy::Bridge::UNDEFINED)
          return {Bridge::WireTags::UNDEFINED => true}
        end
        # A `__js_get__` returns the ABSENT sentinel for a genuinely-missing
        # property: the JS value is `undefined`, but the proxy reports it absent
        # for `in` (see host_runtime.js get/has traps).
        if value.equal?(Dommy::Bridge::ABSENT)
          return {Bridge::WireTags::ABSENT => true}
        end
        # A byte buffer tagged ArrayBuffer crosses back as a bare ArrayBuffer
        # (checked before Bytes, since ArrayBuffer < Bytes).
        if value.is_a?(Dommy::Bridge::ArrayBuffer)
          return {Bridge::WireTags::ARRAY_BUFFER => value.to_a}
        end
        # A byte buffer crosses back as a JS Uint8Array.
        if value.is_a?(Dommy::Bridge::Bytes)
          return {Bridge::WireTags::BYTES => value.to_a}
        end
        # An opaque JS value returns as its original JS object (identity kept).
        if value.is_a?(Dommy::Bridge::JSValue)
          return {Bridge::WireTags::JS_REF => value.ref}
        end
        # A host-created native error crossing as a VALUE (e.g. a promise's
        # rejection reason that must be `instanceof TypeError`): rebuild the real
        # JS error on the other side rather than flattening it to a plain object.
        if value.is_a?(Dommy::Bridge::TypeError) || value.is_a?(Dommy::Bridge::RangeError)
          return {Bridge::WireTags::ERROR_VALUE => native_error_payload(value)}
        end
        # A JS EventListener object wrapped on the way in returns as that same JS
        # object (so removeEventListener(el, this) reaches the right listener).
        if value.is_a?(HostEventListener)
          return {Bridge::WireTags::JS_REF => value.ref}
        end

        # A host collection that subclasses Array (e.g. Dommy::NodeList < Array)
        # must cross as a proxy carrying its DOM interface — so `instanceof
        # NodeList`, `.item()` and the NodeList iterator work — rather than being
        # flattened to a plain JS array by the `when Array` branch below. Plain
        # Arrays (not bridgeable) still map element-wise.
        if value.is_a?(Array) && bridgeable?(value)
          return wrap_handle(value)
        end

        case value
        when Array
          value.map { |element| wrap(element) }
        when Hash
          value.transform_values { |element| wrap(element) }
        when HostCallback
          # A JS function that crossed into Ruby returns as the same live JS
          # function (not a proxy), so callbacks nested in objects round-trip.
          {Bridge::WireTags::CALLBACK => value.id}
        else
          if bridgeable?(value)
            wrap_handle(value)
          else
            value
          end
        end
      end

      # A handle wire value, tagged with the host object's interface name (and
      # custom-element tag when applicable) so makeProxy can build the proxy from
      # a cached per-interface descriptor and skip a `__rb_host_describe` round
      # trip — the bridge's biggest avoidable cost when JS walks/creates many
      # nodes (each new proxy otherwise describes, even for a shared interface).
      def wrap_handle(value)
        ref = {Bridge::WireTags::HANDLE => @handles.register(value)}
        if (name = interface_name(value))
          ref[Bridge::WireTags::INTERFACE] = name
        end
        if value.respond_to?(:__js_custom_element_name__) && (ce = value.__js_custom_element_name__)
          ref[Bridge::WireTags::CUSTOM_ELEMENT] = ce
        end
        ref
      end

      # The host object's interface name (chain.first), cached by class — the
      # name->descriptor mapping is per-interface, so this lookup is the cheap
      # half of avoiding the describe crossing. A class whose interface depends
      # on the INSTANCE (one Ruby class backs every CSS rule) is asked every
      # time, or the first rule seen would name the interface for all of them.
      def interface_name(value)
        return derive_interface_name(value) if DomInterfaces.polymorphic?(value)

        @interface_name_cache ||= {}
        klass = value.class
        return @interface_name_cache[klass] if @interface_name_cache.key?(klass)

        @interface_name_cache[klass] = derive_interface_name(value)
      end

      def derive_interface_name(value)
        DomInterfaces.info(value)["name"]
      rescue StandardError
        nil
      end

      # A value crosses as a proxy if it implements any of the bridge ABI — not
      # only __js_get__: method-only objects (observers) and constructors expose
      # __js_call__ / __js_new__ without properties.
      def bridgeable?(value)
        value.respond_to?(:__js_get__) ||
          value.respond_to?(:__js_call__) ||
          value.respond_to?(:__js_new__)
      end

      # The tagged Hash shapes #unwrap knows, as tag key -> the builder that
      # rebuilds the Ruby value. A table rather than an `elsif` chain, so a new
      # WireTag is one entry here and its mirror in host_runtime.js. A tagged
      # Hash carries exactly one of these keys (a handle's INTERFACE, a ref's
      # JS_STACK and friends are decoration), so the first hit is the shape.
      TAG_BUILDERS = {
        Bridge::WireTags::HANDLE => :unwrap_handle,
        Bridge::WireTags::CALLBACK => :unwrap_callback,
        Bridge::WireTags::JS_REF => :unwrap_js_ref,
        Bridge::WireTags::UNDEFINED => :unwrap_undefined,
        Bridge::WireTags::ABSENT => :unwrap_absent,
        Bridge::WireTags::BYTES => :unwrap_bytes
      }.freeze

      # JS -> Ruby: rebuild tagged handles / callbacks into Ruby objects.
      def unwrap(value)
        case value
        when Array
          value.map { |element| unwrap(element) }
        when Hash
          builder = tag_builder(value)
          builder ? send(builder, value) : value.transform_values { |element| unwrap(element) }
        when :undefined
          # A bare JS `undefined` (e.g. a property-set value, marshalled
          # directly rather than through the tagged-args path) arrives as the
          # `:undefined` symbol — see the HostBridge backend contract. Normalize
          # it to the same sentinel a tagged top-level undefined produces, so
          # setters can distinguish it from `null` (e.g. `el.ariaLabel =
          # undefined` removes the attribute).
          Dommy::Bridge::UNDEFINED
        else
          value
        end
      end

      # Which of TAG_BUILDERS this Hash carries, or nil for a plain object. Walks
      # the Hash's own keys (a tagged one has very few) instead of probing for
      # every tag in turn.
      def tag_builder(hash)
        hash.each_key do |key|
          builder = TAG_BUILDERS[key]
          return builder if builder
        end
        nil
      end

      # Tolerant: an argument referencing a released/invalid node resolves to nil
      # rather than crashing (e.g. Vue passes a transient handle during v-model
      # setup). A receiver handle still uses strict #host.
      def unwrap_handle(value) = @handles.lookup(value[Bridge::WireTags::HANDLE])

      def unwrap_callback(value)
        id = value[Bridge::WireTags::CALLBACK]
        @callback_objects[id] ||= HostCallback.new(@bridge, id)
      end

      # A live JS object, in one of the three roles the bridge knows: an
      # EventListener, a NodeFilter, or an opaque value Ruby only stores and
      # hands back. The first two are memoized by ref so the same JS object
      # yields the same Ruby wrapper — that is what lets removeEventListener
      # match a listener by identity.
      def unwrap_js_ref(value)
        ref = value[Bridge::WireTags::JS_REF]
        if value[Bridge::WireTags::HANDLE_EVENT]
          @listener_objects[ref] ||= HostEventListener.new(@bridge, ref, value[Bridge::WireTags::JS_LABEL])
        elsif value[Bridge::WireTags::ACCEPT_NODE]
          @filter_objects[ref] ||= HostNodeFilter.new(@bridge, ref)
        else
          Dommy::Bridge::JSValue.new(ref, value[Bridge::WireTags::JS_LABEL],
            Marshaller.stack_frames(value[Bridge::WireTags::JS_STACK]), value[Bridge::WireTags::JS_NAME])
        end
      end

      # A top-level JS `undefined` argument — distinct from JS null (nil).
      def unwrap_undefined(_value) = Dommy::Bridge::UNDEFINED

      # Symmetry with #wrap; an absent marker crossing back is the sentinel.
      def unwrap_absent(_value) = Dommy::Bridge::ABSENT

      # A JS ArrayBuffer / TypedArray argument arrives as a byte buffer.
      def unwrap_bytes(value) = Dommy::Bridge::Bytes.new(value[Bridge::WireTags::BYTES])

      # ---- exception / callback-result marshalling ----

      # Run a host-function body, converting a raised Dommy::DOMException into a
      # tagged marker that the JS side (rehydrate) re-throws as a real
      # DOMException (name + legacy code, `instanceof DOMException`). Otherwise
      # the quickjs gem flattens it to a plain Error — no name/code — which
      # breaks `assert_throws_dom` and every DOM error contract (removeChild
      # NotFoundError, classList SyntaxError/InvalidCharacterError, …).
      def dom_guard
        yield
      rescue Dommy::Bridge::ThrowValue => e
        # A host method threw an arbitrary value (e.g. throwIfAborted's reason);
        # re-throw it verbatim JS-side, identity preserved.
        {Bridge::WireTags::THROW => wrap(e.value)}
      rescue Dommy::DOMException => e
        {Bridge::WireTags::EXCEPTION => {"name" => e.name, "message" => e.message, "code" => e.code}}
      rescue Dommy::Bridge::TypeError, Dommy::Bridge::RangeError => e
        # A deliberate, spec-mandated JS TypeError (`new URL(bad)`) or RangeError
        # (`new Response(b, {status: 42})`). Tagged so rehydrate rethrows the real
        # constructor — `assert_throws_js(TypeError, …)` checks `instanceof
        # TypeError`, which a DOMException/Error fails.
        {Bridge::WireTags::EXCEPTION => native_error_payload(e)}
      end

      # The wire shape of a JS-native error. One description for both the thrown
      # form (EXCEPTION, rethrown JS-side) and the value form (ERROR_VALUE, e.g.
      # a promise's rejection reason), which differ only in the tag they sit
      # under — rehydrate builds the same error object from either.
      def native_error_payload(error)
        name = error.is_a?(Dommy::Bridge::RangeError) ? "RangeError" : "TypeError"
        {"name" => name, "message" => error.message, "js_native" => true}
      end

      # A callback's return value, or — when the JS side tagged the result as a
      # throw ("__rb_cb_threw__") — the thrown value re-raised (raising) or
      # swallowed (the default, returning nil).
      def callback_result(raw, raising)
        if raw.is_a?(Hash) && raw.key?(Bridge::WireTags::CALLBACK_THREW)
          raise thrown_value(raw[Bridge::WireTags::CALLBACK_THREW]) if raising

          return nil
        end
        unwrap(raw)
      end

      # A callback's thrown value as a raisable Ruby error, carrying the JS
      # frames as its backtrace so the host can report where the page failed.
      # Without them a listener or timer callback that throws reports position
      # 0:0, since the value itself is opaque once it has crossed.
      def thrown_value(tag)
        error = Dommy::Bridge::ThrowValue.new(unwrap(tag))
        frames = Marshaller.stack_frames(tag[Bridge::WireTags::JS_STACK]) if tag.is_a?(Hash)
        error.set_backtrace(frames) if frames && !frames.empty?
        error
      end
    end
  end
end
