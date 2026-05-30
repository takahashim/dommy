# frozen_string_literal: true

module Dommy
  # Invokes a callback that may be a JS-bridged object (responds to `__js_call__`)
  # or a plain Ruby callable (responds to `call`). Centralizes the dispatch used
  # by promises, the scheduler, and streams so the JS/Ruby fork lives in one place.
  module CallableInvoker
    module_function

    # Invoke `callback` with `args`. A JS-bridged callable goes through
    # `__js_call__("call", args)`; a Ruby callable through `call(*args)`. A nil
    # or non-callable callback is a no-op (returns nil).
    def invoke(callback, *args)
      return if callback.nil?

      if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", args)
      elsif callback.respond_to?(:call)
        callback.call(*args)
      end
    end

    # Invoke a DOM event listener per the EventTarget rule: an object with
    # `handle_event`, else a Ruby callable, else a JS-bridged callable (tried in
    # that order).
    def invoke_listener(listener, event)
      if listener.respond_to?(:handle_event)
        listener.handle_event(event)
      elsif listener.respond_to?(:call) && !listener.is_a?(Module)
        listener.call(event)
      elsif listener.respond_to?(:__js_call__)
        listener.__js_call__("call", [event])
      end
    end
  end
end
