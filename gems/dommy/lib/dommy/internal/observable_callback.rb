# frozen_string_literal: true

module Dommy
  module Internal
    # Shared callback-invocation contract for the observer trio
    # (IntersectionObserver / ResizeObserver / PerformanceObserver).
    #
    # Observers accept either a JS-bridge object (anything responding
    # to `__js_call__("call", args)`) or a plain Ruby Proc. The
    # invocation order here matches how the JS bridge wires user code
    # into the polyfill — try the bridge first, then fall back to a
    # native callable.
    module ObservableCallback
      private

      def invoke_callback(entries)
        if @callback.respond_to?(:__js_call__)
          @callback.__js_call__("call", [entries, self])
        elsif @callback.respond_to?(:call)
          @callback.call(entries, self)
        end
      end
    end
  end
end
