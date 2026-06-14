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
      def initialize(bridge)
        @bridge = bridge
        @handles = HandleTable.new
        @callback_objects = {}
        @listener_objects = {}
        @filter_objects = {}
      end

      # ---- handle table (cross-boundary object identity) ----

      def register(obj) = @handles.register(obj)
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
          return {WireTags::UNDEFINED => true}
        end
        # A byte buffer tagged ArrayBuffer crosses back as a bare ArrayBuffer
        # (checked before Bytes, since ArrayBuffer < Bytes).
        if value.is_a?(Dommy::Bridge::ArrayBuffer)
          return {WireTags::ARRAY_BUFFER => value.to_a}
        end
        # A byte buffer crosses back as a JS Uint8Array.
        if value.is_a?(Dommy::Bridge::Bytes)
          return {WireTags::BYTES => value.to_a}
        end
        # An opaque JS value returns as its original JS object (identity kept).
        if value.is_a?(Dommy::Bridge::JSValue)
          return {WireTags::JS_REF => value.ref}
        end
        # A JS EventListener object wrapped on the way in returns as that same JS
        # object (so removeEventListener(el, this) reaches the right listener).
        if value.is_a?(HostEventListener)
          return {WireTags::JS_REF => value.ref}
        end

        # A host collection that subclasses Array (e.g. Dommy::NodeList < Array)
        # must cross as a proxy carrying its DOM interface — so `instanceof
        # NodeList`, `.item()` and the NodeList iterator work — rather than being
        # flattened to a plain JS array by the `when Array` branch below. Plain
        # Arrays (not bridgeable) still map element-wise.
        if value.is_a?(Array) && bridgeable?(value)
          return {WireTags::HANDLE => @handles.register(value)}
        end

        case value
        when Array
          value.map { |element| wrap(element) }
        when Hash
          value.transform_values { |element| wrap(element) }
        when HostCallback
          # A JS function that crossed into Ruby returns as the same live JS
          # function (not a proxy), so callbacks nested in objects round-trip.
          {WireTags::CALLBACK => value.id}
        else
          if bridgeable?(value)
            {WireTags::HANDLE => @handles.register(value)}
          else
            value
          end
        end
      end

      # A value crosses as a proxy if it implements any of the bridge ABI — not
      # only __js_get__: method-only objects (observers) and constructors expose
      # __js_call__ / __js_new__ without properties.
      def bridgeable?(value)
        value.respond_to?(:__js_get__) ||
          value.respond_to?(:__js_call__) ||
          value.respond_to?(:__js_new__)
      end

      # JS -> Ruby: rebuild tagged handles / callbacks into Ruby objects.
      def unwrap(value)
        case value
        when Array
          value.map { |element| unwrap(element) }
        when Hash
          if value.key?(WireTags::HANDLE)
            # Tolerant: an argument referencing a released/invalid node resolves
            # to nil rather than crashing (e.g. Vue passes a transient handle
            # during v-model setup). A receiver handle still uses strict #host.
            @handles.lookup(value[WireTags::HANDLE])
          elsif value.key?(WireTags::CALLBACK)
            id = value[WireTags::CALLBACK]
            @callback_objects[id] ||= HostCallback.new(@bridge, id)
          elsif value.key?(WireTags::JS_REF)
            ref = value[WireTags::JS_REF]
            if value[WireTags::HANDLE_EVENT]
              # A JS object implementing EventListener (handleEvent). Wrap it as a
              # Ruby listener whose #handle_event routes back to its handleEvent.
              # Memoized by ref so the same JS object yields the same wrapper,
              # letting removeEventListener match the listener by identity.
              @listener_objects[ref] ||= HostEventListener.new(@bridge, ref, value[WireTags::JS_LABEL])
            elsif value[WireTags::ACCEPT_NODE]
              # A NodeFilter callback-interface object. Wrap it so a traversal
              # invokes acceptNode on the live JS object (fresh getter, this =
              # object, exceptions propagated).
              @filter_objects[ref] ||= HostNodeFilter.new(@bridge, ref)
            else
              # An opaque JS value (a non-plain object Ruby just stores and
              # returns, e.g. an abort reason) — kept as a handle so it
              # round-trips with identity rather than being flattened to a Hash.
              Dommy::Bridge::JSValue.new(ref, value[WireTags::JS_LABEL])
            end
          elsif value.key?(WireTags::UNDEFINED)
            # A top-level JS `undefined` argument — distinct from JS null (nil).
            Dommy::Bridge::UNDEFINED
          elsif value.key?(WireTags::BYTES)
            # A JS ArrayBuffer / TypedArray argument arrives as a byte buffer.
            Dommy::Bridge::Bytes.new(value[WireTags::BYTES])
          else
            value.transform_values { |element| unwrap(element) }
          end
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
        {WireTags::THROW => wrap(e.value)}
      rescue Dommy::DOMException => e
        {WireTags::EXCEPTION => {"name" => e.name, "message" => e.message, "code" => e.code}}
      rescue Dommy::Bridge::TypeError => e
        # A deliberate, spec-mandated JS TypeError (e.g. `new URL(bad)`). Tagged
        # so rehydrate rethrows a real `TypeError` — `assert_throws_js(TypeError,
        # …)` checks `instanceof TypeError`, which a DOMException/Error fails.
        {WireTags::EXCEPTION => {"name" => "TypeError", "message" => e.message, "js_native" => true}}
      rescue Dommy::Bridge::RangeError => e
        # A spec-mandated JS RangeError (e.g. `new Response(b, {status: 42})`).
        {WireTags::EXCEPTION => {"name" => "RangeError", "message" => e.message, "js_native" => true}}
      end

      # A callback's return value, or — when the JS side tagged the result as a
      # throw ("__rb_cb_threw__") — the thrown value re-raised (raising) or
      # swallowed (the default, returning nil).
      def callback_result(raw, raising)
        if raw.is_a?(Hash) && raw.key?(WireTags::CALLBACK_THREW)
          raise Dommy::Bridge::ThrowValue.new(unwrap(raw[WireTags::CALLBACK_THREW])) if raising

          return nil
        end
        unwrap(raw)
      end
    end
  end
end
