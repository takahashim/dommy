# frozen_string_literal: true

module Dommy
  module Internal
    # Shared callback-invocation contract for the observer trio
    # (IntersectionObserver / ResizeObserver / PerformanceObserver).
    #
    # Observers accept a JS function or a Ruby callable; CallableInvoker
    # tells the two apart.
    module ObservableCallback
      private

      def invoke_callback(entries)
        CallableInvoker.invoke(@callback, entries, self)
      end
    end
  end
end
