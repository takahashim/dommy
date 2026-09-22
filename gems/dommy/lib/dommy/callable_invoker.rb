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

    # Invoke `callback` so a JS throw SURFACES as a Ruby exception instead of
    # being swallowed by the bridge. WHATWG requires a task's exception to be
    # reported at the global ("report an exception") rather than silently
    # dropped, so the entry points that own a task — a timer / rAF callback —
    # invoke this form and report whatever comes out. The plain `invoke` keeps
    # the swallowing behavior for callers that handle their own errors.
    def invoke_raising(callback, *args)
      return if callback.nil?

      if callback.respond_to?(:__js_invoke__)
        callback.__js_invoke__(args, raising: true)
      else
        invoke(callback, *args)
      end
    end

    # Invoke a DOM event listener per the EventTarget rule: an object with
    # `handle_event`, else a Ruby callable, else a JS-bridged callable (tried in
    # that order). A JS function listener's `this` must be the event's
    # currentTarget (the node the listener is attached to), so pass it through
    # when the bridge supports an explicit receiver.
    # `args:` overrides the single-event argument list — the special error
    # event handler (`window.onerror`) is called with (message, filename,
    # lineno, colno, error) instead of the event. An EventListener object's
    # handleEvent always receives the event.
    def invoke_listener(listener, event, current_target = nil, args: nil)
      args ||= [event]
      if listener.respond_to?(:handle_event)
        listener.handle_event(event)
      elsif listener.respond_to?(:call) && !listener.is_a?(Module)
        listener.call(*args)
      elsif listener.respond_to?(:__js_invoke__)
        # A JS function listener: `this` is the currentTarget, and a thrown value
        # surfaces (as a ThrowValue) so the dispatch reports it as a window
        # `error` event instead of swallowing it.
        listener.__js_invoke__(args, this: current_target, raising: true)
      elsif listener.respond_to?(:__js_call__)
        listener.__js_call__("call", args)
      end
    end
  end
end
