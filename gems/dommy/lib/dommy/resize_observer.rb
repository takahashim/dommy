# frozen_string_literal: true

module Dommy
  # `ResizeObserver` — stub for the element-resize API. Same shape as
  # IntersectionObserver: observe / unobserve / disconnect, plus
  # `__test_trigger__` for tests to drive callbacks.
  #
  # Spec: https://drafts.csswg.org/resize-observer/
  class ResizeObserver
    include Internal::ObservableCallback

    attr_reader :callback

    def initialize(callback)
      @callback = callback
      @targets = []
    end

    def observe(target, _options = nil)
      @targets << target unless @targets.include?(target)
      nil
    end

    def unobserve(target)
      @targets.delete(target)
      nil
    end

    def disconnect
      @targets.clear
      nil
    end

    def observed_targets
      @targets.dup
    end

    def __test_trigger__(entries)
      invoke_callback(entries)
    end

    def __js_call__(method, args)
      case method
      when "observe"
        observe(args[0], args[1])
      when "unobserve"
        unobserve(args[0])
      when "disconnect"
        disconnect
      end
    end
  end
end
