# frozen_string_literal: true

module Dommy
  # `Dommy::Bridge` — adapter classes for JS-style bridges (wasm
  # embedders that route DOM method calls and constructor `new` ops
  # through the `__js_get__` / `__js_set__` / `__js_call__` /
  # `__js_new__` protocol).
  #
  # CRuby users writing happy-dom-style tests can ignore everything
  # in this namespace; it's only relevant when integrating Dommy
  # with an external runtime (such as an mruby-on-wasm host) that
  # constructs callbacks / events / promises via the bridge view.
  #
  # The protocol contract:
  #   - `__js_get__(name)` reads a JS-style property by string name
  #   - `__js_set__(name, value)` writes one
  #   - `__js_call__(method, args)` invokes a method with positional
  #     args (Array)
  #   - `__js_new__(args)` invokes the value as a JS constructor
  module Bridge
    # Sentinel returned by `__js_set__` when a key is not a known DOM property
    # (so the JS host can keep it as a JS-side expando, preserving identity)
    # rather than silently dropping it.
    UNHANDLED = :__js_unhandled__

    # Sentinel for the JS `undefined` value, used in both directions:
    #   - a `__js_call__` returns it for a void (undefined-returning) op, so the
    #     host marshals JS `undefined` rather than the `null` a bare Ruby `nil`
    #     would (e.g. DOMTokenList add/remove return undefined);
    #   - a top-level JS `undefined` *argument* arrives as it (whereas JS `null`
    #     arrives as `nil`), so WebIDL-style dispatch can tell an omitted optional
    #     argument from an explicit null.
    # Its `to_s` is "undefined" so a DOMString coercion of a stray undefined is
    # still spec-faithful.
    UNDEFINED = Object.new
    def UNDEFINED.to_s = "undefined"
    def UNDEFINED.inspect = "#<Dommy::Bridge::UNDEFINED>"
    UNDEFINED.freeze

    # A Ruby-side signal that the JS boundary should surface a JS `TypeError`
    # (not a `DOMException`). Some WebIDL operations — notably the `URL`
    # constructor and its `href` setter — throw `TypeError` on failure rather
    # than a DOMException; raising this lets a host bridge rethrow the correct
    # JS error type, while Ruby callers can still rescue it like any other
    # error. Kept distinct from Ruby's built-in `::TypeError` so a host can map
    # only deliberate, spec-mandated TypeErrors (and not mask genuine Ruby type
    # bugs) across the boundary.
    class TypeError < ::StandardError; end

    # Wraps an external callback handle (registered in a host-side
    # callback table) so the JS bridge can resolve / invoke it. The
    # external host that creates these is responsible for honoring
    # `invoke_callback(callback_id, args)`.
    #
    # The `__callback_id__` key on this object exposes the integer
    # id to JS-side code that needs to round-trip it (e.g. for
    # release / introspection).
    class Callback
      ID_KEY = "__callback_id__"

      def initialize(host, callback_id)
        @host = host
        @callback_id = callback_id
        @props = {}
      end

      def __js_get__(key)
        if key == ID_KEY
          @props.fetch(key, @callback_id)
        else
          @props[key]
        end
      end

      def __js_set__(key, value)
        @props[key] = value
        nil
      end

      def __js_call__(method, args)
        case method
        when "call"
          @host.invoke_callback(@callback_id, args)
        end
      end
    end

    # Block-as-constructor adapter — invoking `__js_new__(args)`
    # calls the wrapped block with `args` and returns whatever the
    # block produces. Used by Window to wire up `new Event(init)`,
    # `new CustomEvent(init)`, etc. without hand-rolling a class
    # for each constructor.
    class Constructor
      def initialize(&block)
        @block = block
        @class_methods = {}
      end

      def __js_new__(args)
        @block.call(args)
      end

      # Register a class-level method (e.g. `URL.createObjectURL`)
      # that JS bridges resolve via `__js_call__` on the constructor
      # itself. Returns self for chaining.
      def define_class_method(name, &block)
        @class_methods[name.to_s] = block
        self
      end

      def __js_call__(method, args)
        handler = @class_methods[method.to_s]
        handler&.call(args)
      end

      # Names of the registered class-level (static) methods, so a JS host can
      # expose them on the constructor function (e.g. `URL.createObjectURL`).
      def __js_class_method_names__
        @class_methods.keys
      end
    end

    # `JS.global[:Promise]` view. Implements the `resolve` / `reject`
    # class methods plus `new Promise(executor)` via `__js_new__`.
    class PromiseConstructor
      def initialize(window)
        @window = window
      end

      def __js_call__(method, args)
        case method
        when "resolve"
          PromiseValue.resolve(@window, args[0])
        when "reject"
          PromiseValue.reject(@window, args[0])
        end
      end

      # `new Promise(executor)` — runs executor synchronously with
      # (resolve, reject) callbacks.
      def __js_new__(args)
        executor = args[0]
        promise = PromiseValue.new(@window)
        resolve = PromiseSettler.new(promise, fulfilled: true)
        reject = PromiseSettler.new(promise, fulfilled: false)
        if executor.respond_to?(:__js_call__)
          executor.__js_call__("call", [resolve, reject])
        elsif executor.respond_to?(:call)
          executor.call(resolve, reject)
        end

        promise
      end
    end

    # Adapter so a Ruby-side executor can deliver resolve/reject
    # through the same `__js_call__("call", args)` interface that
    # the scheduler and JS bridge use for callbacks.
    class PromiseSettler
      def initialize(promise, fulfilled:)
        @promise = promise
        @fulfilled = fulfilled
      end

      def __js_call__(_method, args)
        if @fulfilled
          @promise.fulfill(args[0])
        else
          @promise.reject(args[0])
        end

        nil
      end
    end
  end
end
