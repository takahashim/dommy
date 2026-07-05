# frozen_string_literal: true

require "json"

module Dommy
  module Js
    # Engine-agnostic core of the JS<->Ruby DOM bridge. Given a `backend` that
    # can evaluate JS, register Ruby host functions, and call back into JS,
    # HostBridge exposes a Ruby object to the JS side as an ES Proxy whose
    # property/method access routes into the bridge ABI:
    #   __js_get__(name) / __js_set__(name, value) / __js_call__(method, args)
    #
    # Nothing here is QuickJS-specific; this layer is intended to move into a
    # future `dommy-js` gem with QuickJS/wasm backends plugged in underneath.
    #
    # Collaborators keep the bridge focused on the engine ABI:
    #   Marshaller          — Ruby<->JS value conversion + the handle/callback
    #                         identity tables (#wrap / #unwrap, delegated below)
    #   DomInterfaces       — interface name/chain derivation (instanceof support)
    #   ConstructorResolver — `new Event(...)` style reverse construction
    #   CustomElementBridge — JS customElements.define -> Dommy wiring
    #
    # Backend contract:
    #   backend.eval(js)                         -> evaluate top-level JS
    #   backend.define_host_function(name) { }   -> expose a Ruby block as a JS global
    #   backend.call_js(path, *args)             -> invoke a JS global function by path
    #   backend.run_bundle(cache_key, source)    -> run a reused-across-VMs source
    #                                               bundle (engine may compile-cache)
    #
    # Value representation a backend must deliver across the boundary (host
    # function arguments and call_js results): JSON-ish Ruby values
    # (Hash/Array/String/Numeric/true/false/nil) carrying the WireTags protocol.
    # The backend does NOT need to distinguish JS `undefined` from `null` in its
    # value marshalling: host_runtime.js tags every top-level `undefined` crossing
    # to Ruby (dehydrateTop — callback/host returns, property-set values, call
    # args) as `{__rb_undefined: true}`, so it arrives as Dommy::Bridge::UNDEFINED
    # regardless of the engine (V8/mini_racer cannot tell the two apart, and need
    # not). As a defensive fallback, the bridge also normalizes a *bare* JS
    # `undefined` delivered as the Ruby symbol `:undefined` (a backend that can
    # produce it, like QuickJS) to Dommy::Bridge::UNDEFINED, but no backend is
    # required to.
    #
    # The host object must implement __js_get__/__js_set__/__js_call__, and the
    # bridge needs to know which names are methods (callable via __js_call__)
    # vs. properties (read via __js_get__) — see #method_names.
    class HostBridge
      # JS half of the bridge (globalThis.__rbHost). Read from a companion file
      # so it stays lintable/highlightable rather than buried in a heredoc.
      # ::File — inside module Dommy, bare `File` resolves to Dommy::File (the
      # File API class), not Ruby's file class. These bundles are identical
      # across VMs; the backend's #run_bundle keeps them parsed once per process,
      # so the bridge itself stays free of any bytecode/engine knowledge.
      HOST_RUNTIME_JS = ::File.read(::File.join(__dir__, "host_runtime.js")).freeze
      # The WICG Observable polyfill (Observable/Subscriber + EventTarget.when),
      # evaluated after the DOM interface prototypes are seeded.
      OBSERVABLE_RUNTIME_JS = ::File.read(::File.join(__dir__, "observable_runtime.js")).freeze

      def initialize(backend)
        @backend = backend
        @crossing_counts = crossing_profile_enabled? ? new_crossing_counts : nil
        # The marshaller owns value conversion + the handle/callback identity
        # tables; the bridge keeps the engine ABI and lifecycle wiring.
        @codec = Marshaller.new(self)
        @constructor_resolver = ConstructorResolver.new
        @custom_element_bridge = CustomElementBridge.new(self)
        @microtask_procs = {}
        @microtask_seq = 0
        @rejection_details = [] # opt-in rejection-debug capture (see take_rejection_detail)
        install!
      end

      # Bind a Ruby object to a JS global of the given name.
      def define_host_object(name, obj)
        handle = @codec.register(obj)
        @backend.eval("globalThis[#{name.to_s.to_json}] = __rbHost.makeProxy(#{handle}); undefined;")
        obj
      end

      # Bind the window the bridge draws on for JS constructors (new Event(...))
      # and custom element registration. Called by Runtime#install_window — kept
      # distinct from define_host_object so the generic binder has no hidden
      # side effects.
      def window=(win)
        @window = win # the window host promises (thenable adoption) schedule on
        @constructor_resolver.source = win
        @custom_element_bridge.window = win
        # Now that constructors are resolvable, expose their static methods
        # (URL.createObjectURL, …) on the seeded interface globals, and expose
        # the constructors themselves on the window proxy (window.Node,
        # document.defaultView.DOMException, …).
        @backend.call_js("__rbHost.attachStatics")
        @backend.call_js("__rbHost.exposeConstructorsOnWindow")
        wire_scheduler!(win)
        wire_script_runner!(win)
      end

      # Enqueue a Ruby callback as a NATIVE microtask (a resolved-promise job), so
      # it runs in FIFO order with the engine's other promise jobs.
      def schedule_native_microtask(callback)
        id = (@microtask_seq += 1)
        @microtask_procs[id] = callback
        @backend.call_js("__rbHost.scheduleMicrotask", id)
        nil
      end

      # Expose the seeded interface constructors (Element, Node, DOMException, …)
      # on a secondary window object — an iframe's contentWindow — so cross-window
      # `instanceof subWin.Element` and `subDoc.defaultView.DOMException` resolve
      # to the same constructors the top window uses. Idempotent per window.
      def expose_constructors_on(window_obj)
        handle = @codec.register(window_obj)
        # Retain the proxy in a JS-side registry: the constructors are defined as
        # own properties on the proxy's target, so the proxy must stay alive (and
        # keep its handle) — otherwise GC releases it and a later
        # `iframe.contentWindow` rebuilds a fresh, constructor-less proxy.
        @backend.eval(<<~JS)
          (globalThis.__rbSubWindows ||= []).push(__rbHost.makeProxy(#{handle}));
          __rbHost.exposeConstructorsOnWindow(globalThis.__rbSubWindows.at(-1));
        JS
        window_obj
      end

      # Invoke a JS custom element lifecycle callback (connectedCallback etc.) for
      # a Dommy node. Called by the bridged custom element class (see CustomElementBridge).
      def invoke_lifecycle(node, callback, args)
        handle = @codec.register(node)
        unwrap(@backend.call_js("__rbHost.invokeLifecycle", handle, callback, wrap(Array(args))))
      end

      # Invoke a retained live JS function by id (used by HostCallback). The JS
      # side returns a `dehydrate`d (tagged) value, so unwrap it back to Ruby:
      # a callback that returns e.g. a Promise proxy must come back as the live
      # PromiseValue, otherwise Dommy can't adopt it (breaking
      # `fetch().then(r => r.json()).then(…)` chains).
      # `raising: true` re-raises a thrown value (as a ThrowValue dom_guard
      # rethrows verbatim) where the spec requires the exception to propagate — a
      # NodeFilter whose error must surface out of the traversal method that ran
      # it. The default swallows it: event listeners / observers / timers must not
      # let a callback error escape their dispatch.
      def invoke_callback(id, args, this_arg = nil, raising: false)
        callback_result(@backend.call_js("__rbHost.invokeCallback", id, wrap(Array(args)), wrap(this_arg)), raising)
      end

      # Invoke a JS EventListener *object*'s handleEvent (see HostEventListener),
      # passing the dispatched event as a proxy.
      def invoke_js_ref_handle_event(ref, event)
        unwrap(@backend.call_js("__rbHost.invokeJsRefHandleEvent", ref, wrap(event)))
      end

      # Invoke a JS NodeFilter object's acceptNode (see HostNodeFilter). `raising`
      # re-raises a thrown value (the traversal must propagate it) rather than
      # swallowing it.
      def invoke_js_ref_accept_node(ref, node, raising: false)
        callback_result(@backend.call_js("__rbHost.invokeJsRefAcceptNode", ref, wrap(node)), raising)
      end

      # Turn a JS-side tagged value (produced by __rbHost.tag) back into Ruby:
      # tagged handles become the original Ruby DOM objects. Used for return
      # values that may contain DOM nodes (e.g. evaluate_script).
      def decode(tagged)
        unwrap(tagged)
      end

      # Number of live handle entries. Introspection for lifetime tests.
      def registered_count
        @codec.size
      end

      # Snapshot bridge crossing counts, enabled with DOMMY_JS_BRIDGE_PROFILE=1.
      # Counts are grouped by ABI function name, with a nested breakdown of the
      # hottest interface/property or interface/method labels where available.
      def crossing_counts(limit: nil)
        return {} unless @crossing_counts

        @crossing_counts.transform_values do |counts|
          sorted = counts.sort_by { |(_key, count)| -count }
          sorted = sorted.first(limit) if limit
          sorted.to_h
        end
      end

      def reset_crossing_counts
        @crossing_counts = new_crossing_counts if @crossing_counts
        self
      end

      # Drain the most-recent recorded rejection detail (paired by recency with the
      # engine's detail-less "[object Object]" report). Nil when none recorded /
      # the opt-in tracker (installRejectionTracker) isn't installed.
      def take_rejection_detail
        @rejection_details.pop
      end

      private

      def crossing_profile_enabled?
        !ENV["DOMMY_JS_BRIDGE_PROFILE"].to_s.empty?
      end

      def new_crossing_counts
        Hash.new { |h, k| h[k] = Hash.new(0) }
      end

      def count_crossing(abi_name, obj = nil, member = nil)
        return unless @crossing_counts

        @crossing_counts[abi_name.to_s]["__total__"] += 1
        return unless member

        @crossing_counts[abi_name.to_s][crossing_label(obj, member)] += 1
      end

      def crossing_label(obj, member)
        return member.to_s unless obj

        iface = obj ? DomInterfaces.info(obj)["name"] : nil
        "#{iface || obj.class.name}##{member}"
      rescue StandardError
        "#{obj.class.name}##{member}"
      end

      # Route Dommy's host-side microtasks (MutationObserver delivery, …) onto
      # the engine's native promise-job queue, so they interleave FIFO with JS
      # `await`/Promise reactions instead of draining on a separate pass (which
      # would deliver e.g. MutationObserver records only after `await
      # Promise.resolve()`, batching several mutations into one callback).
      def wire_scheduler!(win)
        return unless win.respond_to?(:scheduler) && win.scheduler.respond_to?(:native_microtask_scheduler=)

        win.scheduler.native_microtask_scheduler = ->(callback) { schedule_native_microtask(callback) }
      end

      # Let a classic <script> inserted into the document execute (Dommy has no
      # JS engine; it calls back here to run the body in global scope).
      def wire_script_runner!(win)
        return unless win.respond_to?(:document) && win.document.respond_to?(:script_runner=)

        win.document.script_runner = ->(source) { @backend.call_js("__rbHost.runScript", source.to_s) }
      end

      # Register the host-function ABI in cohesive groups, then run the JS-side
      # runtime that consumes it. Registration order among the groups is
      # irrelevant (they only define functions); seed_runtime! must run last,
      # since the runtime it loads calls back into these functions.
      def install!
        install_object_abi!
        install_lifecycle_abi!
        install_construction_abi!
        install_custom_elements_abi!
        seed_runtime!
      end

      # A host object's property/method ABI, plus the legacy-platform-object
      # named-property protocol (named getter/deleter) and the self-describe call
      # makeProxy uses to build the right JS prototype.
      def install_object_abi!
        @backend.define_host_function("__rb_host_get") do |handle, prop|
          dom_guard do
            obj = host(handle)
            count_crossing(:__rb_host_get, obj, prop)
            wrap(obj.respond_to?(:__js_get__) ? obj.__js_get__(prop) : nil)
          end
        end
        @backend.define_host_function("__rb_host_set") do |handle, prop, value|
          # Returns whether Dommy handled the write as a DOM property. When it
          # didn't (or the object has no __js_set__), the JS side keeps the value
          # as an expando (preserving object/instance field identity). Wrapped in
          # dom_guard so a throwing setter (e.g. `documentElement.outerHTML = …` →
          # NoModificationAllowedError) crosses as a tagged exception the JS set
          # trap re-throws, rather than escaping as a raw Ruby error.
          dom_guard do
            obj = host(handle)
            count_crossing(:__rb_host_set, obj, prop)
            obj.respond_to?(:__js_set__) ? dommy_handled?(obj.__js_set__(prop, unwrap(value))) : false
          end
        end
        @backend.define_host_function("__rb_host_call") do |handle, method, args|
          dom_guard do
            obj = host(handle)
            count_crossing(:__rb_host_call, obj, method)
            obj.respond_to?(:__js_call__) ? wrap(obj.__js_call__(method, unwrap(args))) : nil
          end
        end
        # A pending host PromiseValue used to ADOPT a JS thenable returned from a
        # `.then` callback (Promises/A+): the JS side subscribes the thenable to
        # settle this promise, so the host chain WAITS for the thenable instead of
        # resolving immediately with an opaque ref (the HttpLink #95 reorder).
        @backend.define_host_function("__rb_new_host_promise") do
          count_crossing(:__rb_new_host_promise)
          dom_guard { @codec.register(Dommy::PromiseValue.new(@window)) }
        end
        @backend.define_host_function("__rb_settle_host_promise") do |handle, fulfilled, value|
          count_crossing(:__rb_settle_host_promise)
          dom_guard do
            promise = host(handle)
            fulfilled ? promise.fulfill(unwrap(value)) : promise.reject(unwrap(value))
            nil
          end
        end
        # 2d: one call returns everything makeProxy needs — interface name +
        # chain, method names, and the custom element tag (if any).
        @backend.define_host_function("__rb_host_describe") do |handle|
          obj = host(handle)
          count_crossing(:__rb_host_describe, obj)
          info = DomInterfaces.info(obj)
          info["methods"] = method_names(obj)
          # Mark JS-defined custom elements so makeProxy upgrades them on crossing.
          info["ce"] = obj.__js_custom_element_name__ if obj.respond_to?(:__js_custom_element_name__)
          info
        end
        # One-shot attribute snapshot for the JS-side attribute cache: a plain
        # {qualified_name => value} Hash (an element with case-insensitive
        # attribute lookups), or nil (anything else — the JS side keeps the
        # per-call path). Staleness is the JS side's concern (the DOM epoch).
        @backend.define_host_function("__rb_host_attrs") do |handle|
          dom_guard do
            obj = host(handle)
            count_crossing(:__rb_host_attrs, obj)
            obj.respond_to?(:__js_attribute_snapshot__) ? obj.__js_attribute_snapshot__ : nil
          end
        end
        # WebIDL "supported property names" for a legacy platform object (a live
        # array-like/maplike collection): the current ordered named-property
        # keys. Queried per ownKeys / getOwnPropertyDescriptor so it tracks DOM
        # mutations. Nil when the object has no named getter.
        @backend.define_host_function("__rb_named_props") do |handle|
          obj = host(handle)
          count_crossing(:__rb_named_props, obj)
          obj.respond_to?(:__js_named_props__) ? Array(obj.__js_named_props__).map(&:to_s) : nil
        end
        # Named deleter (`delete el.dataset.foo`): true when the object handled
        # the delete, false/UNHANDLED when the JS side should fall back to its
        # own (expando) delete.
        @backend.define_host_function("__rb_host_delete") do |handle, prop|
          dom_guard do
            obj = host(handle)
            count_crossing(:__rb_host_delete, obj, prop)
            obj.respond_to?(:__js_delete__) ? dommy_handled?(obj.__js_delete__(prop)) : false
          end
        end
      end

      # VM bookkeeping: proxy-handle release (driven by JS GC) and the native
      # microtask drain hook.
      def install_lifecycle_abi!
        @backend.define_host_function("__rb_release_handle") do |handle|
          count_crossing(:__rb_release_handle)
          @codec.release(handle)
          nil
        end
        # Run a Ruby microtask previously registered by schedule_native_microtask,
        # invoked from the resolved-promise job scheduleMicrotask queued.
        @backend.define_host_function("__rb_run_microtask") do |id|
          count_crossing(:__rb_run_microtask)
          callback = @microtask_procs.delete(id)
          callback&.call
          nil
        end
        # Opt-in rejection diagnostics: __rbHost.installRejectionTracker (only run
        # when asked) records a rich description of each promise rejection here, at
        # reject time, so #take_rejection_detail can replace the engine's
        # detail-less "[object Object]" unhandled-rejection report with the truth.
        @backend.define_host_function("__rb_record_rejection_detail") do |detail|
          @rejection_details.push(detail.to_s)
          @rejection_details.shift if @rejection_details.size > 256
          nil
        end
      end

      # Reverse construction (`new Event(...)`) and interface static methods
      # (URL.createObjectURL, …).
      def install_construction_abi!
        # `new Event(...)` / `new DOMException(...)` from a bare interface
        # constructor — resolve the named constructor and build. Returns nil when
        # the interface isn't constructable, so the JS side throws.
        @backend.define_host_function("__rb_construct") do |name, args|
          count_crossing(:__rb_construct, nil, name)
          dom_guard do
            ctor = @constructor_resolver.resolve(name)
            ctor ? wrap(ctor.__js_new__(unwrap(args))) : nil
          end
        end
        # Static/class methods on an interface constructor (URL.createObjectURL,
        # URL.parse, …): names to expose, and the dispatch.
        @backend.define_host_function("__rb_static_names") do |name|
          count_crossing(:__rb_static_names, nil, name)
          ctor = @constructor_resolver.resolve(name)
          ctor.respond_to?(:__js_class_method_names__) ? ctor.__js_class_method_names__ : []
        end
        @backend.define_host_function("__rb_static_call") do |name, method, args|
          count_crossing(:__rb_static_call, nil, "#{name}.#{method}")
          dom_guard do
            ctor = @constructor_resolver.resolve(name)
            ctor.respond_to?(:__js_call__) ? wrap(ctor.__js_call__(method, unwrap(args))) : nil
          end
        end
      end

      # customElements.define / .upgrade, delegated to Dommy's registry.
      def install_custom_elements_abi!
        # 1d: customElements.define(name, JSClass) wires a Dommy custom element.
        @backend.define_host_function("__rb_define_custom_element") do |name, observed|
          count_crossing(:__rb_define_custom_element, nil, name)
          @custom_element_bridge.define(name, Array(observed))
          nil
        end
        # 1d: customElements.upgrade(root) — delegate to Dommy's registry.
        @backend.define_host_function("__rb_upgrade_custom_elements") do |handle|
          count_crossing(:__rb_upgrade_custom_elements)
          @custom_element_bridge.upgrade(host(handle))
          nil
        end
        # 1d: direct `new MyElement()` — mint the backing Dommy element for a
        # registered tag so the HTMLElement constructor has an element to adopt.
        # Returns nil when the tag isn't defined (JS then throws Illegal constructor).
        @backend.define_host_function("__rb_create_custom_element") do |name|
          count_crossing(:__rb_create_custom_element, nil, name)
          dom_guard do
            el = @custom_element_bridge.create(name)
            el ? wrap(el) : nil
          end
        end
      end

      # Run the JS half of the bridge and seed the interface prototypes. Must run
      # after every host function above is registered.
      def seed_runtime!
        @backend.run_bundle("host_runtime.js", HOST_RUNTIME_JS)
        # Seed base interface prototypes from the single Ruby-side hierarchy.
        @backend.eval("__rbHost.seedInterfaces(#{JSON.generate(DomInterfaces::BASE_CHAINS)});")
        # Observable depends on EventTarget.prototype existing (seeded above).
        @backend.run_bundle("observable_runtime.js", OBSERVABLE_RUNTIME_JS)
      end

      # The strict handle lookup for a receiver (raises on a missing handle,
      # unlike the tolerant argument path in Marshaller#unwrap).
      def host(handle)
        @codec.host(handle)
      end

      # Marshalling is the Marshaller's job; the bridge calls these from its ABI
      # blocks and invoke_* helpers.
      def wrap(value) = @codec.wrap(value)
      def unwrap(value) = @codec.unwrap(value)
      def dom_guard(&block) = @codec.dom_guard(&block)
      def callback_result(raw, raising) = @codec.callback_result(raw, raising)

      # Which property names should be treated as callable methods. The ABI
      # keeps properties (__js_get__) and methods (__js_call__) in disjoint
      # namespaces, so the proxy asks the object to self-describe via the bridge
      # ABI method __js_method_names__. method_defined? (not respond_to?) avoids
      # classes whose respond_to_missing? answers true for arbitrary names (e.g.
      # StyleDeclaration's CSS-property accessors).
      def method_names(obj)
        return [] unless obj.class.method_defined?(:__js_method_names__)

        Array(obj.__js_method_names__).map(&:to_s)
      end

      # Did Dommy treat a __js_set__ as a real DOM property? A returned UNHANDLED
      # sentinel means "no" (the JS side then keeps it as an expando).
      def dommy_handled?(result)
        result != Dommy::Bridge::UNHANDLED
      end
    end

    # An event listener backed by a live JS function. Implements only the bridge
    # ABI (__js_call__) — not #call/#handle_event — so Dommy's invoke_listener
    # routes through the __js_call__("call", [event]) branch.
    class HostCallback
      attr_reader :id

      def initialize(bridge, id)
        @bridge = bridge
        @id = id
      end

      def __js_call__(method, args)
        return nil unless method == "call"

        @bridge.invoke_callback(@id, args)
      end

      # Invoke with an explicit `this` receiver — e.g. a MutationObserver
      # callback whose `this` must be the observer, or an event listener whose
      # `this` is the currentTarget.
      def __js_call_with_this__(args, this_arg)
        @bridge.invoke_callback(@id, args, this_arg)
      end

      # Invoke and re-raise a thrown value instead of swallowing it — for a
      # NodeFilter, whose exception must propagate out of the traversal method.
      def __js_call_with_raise__(args)
        @bridge.invoke_callback(@id, args, raising: true)
      end
    end

    # An event listener backed by a live JS *object* implementing the
    # EventListener interface (a `handleEvent` method, e.g. Stimulus's action
    # listeners). Implements #handle_event so Dommy's invoke_listener routes to
    # the object's handleEvent (with `this` bound to the object). Holds the
    # JS-side ref so it also wraps back to the same JS object (identity kept).
    class HostEventListener
      attr_reader :ref

      def initialize(bridge, ref, label = nil)
        @bridge = bridge
        @ref = ref
        @label = label
      end

      def handle_event(event)
        @bridge.invoke_js_ref_handle_event(@ref, event)
      end
    end

    # A NodeFilter backed by a live JS object implementing the callback interface
    # (`{ acceptNode }`). TreeWalker/NodeIterator treat it as the filter callable;
    # each invocation runs acceptNode on the JS object (this = object), and the
    # raising variant lets the filter's exception propagate out of the traversal.
    class HostNodeFilter
      attr_reader :ref

      def initialize(bridge, ref)
        @bridge = bridge
        @ref = ref
      end

      def __js_call__(_method, args)
        @bridge.invoke_js_ref_accept_node(@ref, args[0])
      end

      def __js_call_with_raise__(args)
        @bridge.invoke_js_ref_accept_node(@ref, args[0], raising: true)
      end
    end
  end
end
