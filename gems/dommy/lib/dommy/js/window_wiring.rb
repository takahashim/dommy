# frozen_string_literal: true

module Dommy
  module Js
    # Attaches a window to the realm: everything that has to happen once the
    # bridge knows which window it is driving, in the order it has to happen in.
    #
    #   1. the collaborators that resolve constructors and custom elements are
    #      pointed at the window,
    #   2. the seeded interface globals gain their static methods, and the
    #      window proxy gains the constructors themselves,
    #   3. legacy `window.event` becomes readable as a bare `event`, and
    #   4. Dommy's microtask scheduler and classic-script runner are routed
    #      through the engine.
    #
    # This is a step of its own because it is a procedure, not an assignment:
    # HostBridge#window= used to spell all of it out, which left a setter
    # carrying eight side effects and no name for the thing they add up to.
    class WindowWiring
      def initialize(backend, constructor_resolver:, custom_elements:, microtask_scheduler:)
        @backend = backend
        @constructor_resolver = constructor_resolver
        @custom_elements = custom_elements
        @microtask_scheduler = microtask_scheduler
      end

      def attach(window)
        @constructor_resolver.source = window
        @custom_elements.window = window
        expose_constructors!
        @backend.call_js("__rbHost.defineLegacyEventAccessor")
        wire_scheduler!(window)
        wire_script_runner!(window)
        window
      end

      private

      # Now that constructors are resolvable, expose their static methods
      # (URL.createObjectURL, …) on the seeded interface globals, and the
      # constructors themselves on the window proxy (window.Node,
      # document.defaultView.DOMException, …).
      def expose_constructors!
        @backend.call_js("__rbHost.attachStatics")
        @backend.call_js("__rbHost.exposeConstructorsOnWindow")
      end

      # Route Dommy's host-side microtasks (MutationObserver delivery, …) onto
      # the engine's native promise-job queue, so they interleave FIFO with JS
      # `await`/Promise reactions instead of draining on a separate pass (which
      # would deliver e.g. MutationObserver records only after `await
      # Promise.resolve()`, batching several mutations into one callback).
      def wire_scheduler!(window)
        return unless window.respond_to?(:scheduler) && window.scheduler.respond_to?(:native_microtask_scheduler=)

        window.scheduler.native_microtask_scheduler = @microtask_scheduler
      end

      # Let a classic <script> inserted into the document execute (Dommy has no
      # JS engine; it calls back here to run the body in global scope).
      def wire_script_runner!(window)
        return unless window.respond_to?(:document) && window.document.respond_to?(:script_runner=)

        backend = @backend
        window.document.script_runner = ->(source) { backend.call_js("__rbHost.runScript", source.to_s) }
      end
    end
  end
end
