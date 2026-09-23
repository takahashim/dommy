# frozen_string_literal: true

module Dommy
  module Js
    # Ruby adapters for the live JS objects that cross into Dommy as callables:
    # a function, an EventListener object, a NodeFilter object. Each holds only
    # the id or ref the JS side knows it by and routes every invocation back
    # through the bridge, so the object it stands for keeps its identity.
    #
    # They live apart from HostBridge because the Marshaller builds them while
    # unwrapping — defining them alongside the bridge made the two files depend
    # on each other and on the order dommy.rb requires them in.

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

      # The full invocation, with both of the choices a caller has:
      #
      #   this:    the receiver the JS function sees as `this` — a
      #            MutationObserver callback's is the observer, an event
      #            listener's is the currentTarget. nil leaves it to the engine.
      #   raising: re-raise a thrown value (as a ThrowValue, identity intact)
      #            instead of swallowing it — a NodeFilter's exception has to
      #            propagate out of the traversal method, and an event
      #            listener's is caught by the dispatch and reported as a
      #            window `error` event.
      #
      # One method rather than a name per combination: the two choices are
      # independent, and a third would otherwise double the names again.
      def __js_invoke__(args, this: nil, raising: false)
        @bridge.invoke_callback(@id, args, this, raising: raising)
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

      # `this` is fixed on the JS side (acceptNode is called on the filter
      # object itself), so only `raising:` is meaningful here.
      def __js_invoke__(args, this: nil, raising: false)
        _ = this
        @bridge.invoke_js_ref_accept_node(@ref, args[0], raising: raising)
      end
    end
  end
end
