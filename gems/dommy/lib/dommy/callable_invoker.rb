# frozen_string_literal: true

module Dommy
  # Invokes a callback that may be a JS-bridged object (responds to `__js_call__`)
  # or a plain Ruby callable (responds to `call`). Centralizes the dispatch used
  # by promises, the scheduler, and streams so the JS/Ruby fork lives in one place.
  module CallableInvoker
    module_function

    # A callback the page passed from JS — a function, or a NodeFilter
    # object. Told by type, not by answering __js_call__: every host object
    # answers that, for its own methods.
    def js_callable?(callback) = callback.is_a?(Js::Callable)

    # Something #invoke can call: a JS callable, or a Ruby one.
    def callable?(callback) = js_callable?(callback) || callback.respond_to?(:call)

    # Invoke `callback` with `args`, a JS throw swallowed by the bridge. `this:`
    # is the receiver a JS function sees (a Ruby callable has none). A nil or
    # non-callable callback is a no-op (returns nil).
    def invoke(callback, *args, this: nil)
      if js_callable?(callback)
        callback.__js_invoke__(args, this: this)
      elsif callback.respond_to?(:call)
        callback.call(*args)
      end
    end

    # Invoke `callback` so a JS throw SURFACES as a Ruby exception instead of
    # being swallowed by the bridge. WHATWG requires a task's exception to be
    # reported at the global ("report an exception") rather than silently
    # dropped, so the entry points that own a task — a timer / rAF callback, a
    # promise reaction, a NodeFilter — invoke this form and handle whatever
    # comes out. A Ruby callable raises naturally.
    def invoke_raising(callback, *args, this: nil)
      return callback.__js_invoke__(args, this: this, raising: true) if js_callable?(callback)

      invoke(callback, *args)
    end

    # Invoke a DOM event listener per the EventTarget rule: an object with
    # `handle_event`, else a Ruby callable, else a JS function (tried in that
    # order). A JS function listener's `this` is the event's currentTarget,
    # and its throw surfaces so the dispatch reports it as a window `error`
    # event. `args:` overrides the single-event argument list — the special
    # error event handler (`window.onerror`) is called with (message,
    # filename, lineno, colno, error) instead of the event. An EventListener
    # object's handleEvent always receives the event.
    def invoke_listener(listener, event, current_target = nil, args: nil)
      args ||= [event]
      if listener.respond_to?(:handle_event)
        listener.handle_event(event)
      elsif listener.respond_to?(:call) && !listener.is_a?(Module)
        listener.call(*args)
      elsif js_callable?(listener)
        listener.__js_invoke__(args, this: current_target, raising: true)
      end
    end
  end
end
