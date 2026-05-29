# frozen_string_literal: true

module Dommy
  # `Worker` — inline-emulated. Dommy does NOT spin up a separate
  # execution context (no JS engine, no Ruby Thread). Instead:
  #
  #   - `new Worker("/path/to/worker.js")` records the URL.
  #   - The script body is not executed. Tests install message
  #     handlers on the worker-side via `worker.__test_on_message__ { ... }`
  #     to simulate behavior.
  #   - `worker.postMessage(data)` queues a microtask that delivers
  #     to the worker-side handler.
  #   - The worker-side handler can call `worker.__test_post_to_main__(data)`
  #     to deliver a message back to the main side's `message` event.
  #
  # This is enough surface to test "the app correctly posts/receives
  # via Worker" without a real worker runtime.
  #
  # Spec (real): https://html.spec.whatwg.org/multipage/workers.html
  class Worker
    include EventTarget

    attr_reader :url

    def initialize(window, url, _options = nil)
      @window = window
      @url = url.to_s
      @inline_handlers = {}
      @worker_side_handlers = []
      @terminated = false
    end

    # Main-side: post a message to the worker.
    def post_message(data)
      return if @terminated

      cloned = Dommy.structured_clone(data)
      @window.scheduler.queue_microtask(
        proc do
          @worker_side_handlers.each { |h| invoke(h, [{"data" => cloned}]) }
        end
      )

      nil
    end

    alias postMessage post_message

    def terminate
      @terminated = true
      @worker_side_handlers.clear
      nil
    end

    # --- Test seams (worker-side) ----------------------------------

    # Register a callback that runs in the "worker side". Multiple
    # registrations stack.
    def __test_on_message__(&block)
      @worker_side_handlers << block
    end

    # Worker-side: deliver a message to the main-side `message` event.
    def __test_post_to_main__(data)
      cloned = Dommy.structured_clone(data)
      @window.scheduler.queue_microtask(
        proc do
          dispatch_event(MessageEvent.new("message", "data" => cloned))
        end
      )

      nil
    end

    # --- JS bridge -------------------------------------------------

    def __js_get__(key)
      case key
      when "url"
        @url
      else
        @inline_handlers[inline_event_for(key)]
      end
    end

    def __js_set__(key, value)
      event = inline_event_for(key)
      return Bridge::UNHANDLED unless event

      set_inline_handler(event, value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "postMessage"
        post_message(args[0])
      when "terminate"
        terminate
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end

    private

    INLINE_HANDLERS = %w[message error messageerror].freeze
    INLINE_EVENT_MAP = INLINE_HANDLERS
      .each_with_object({}) do |name, h|
        h["on#{name}"] = name
      end
      .freeze

    def inline_event_for(key)
      INLINE_EVENT_MAP[key.to_s]
    end

    def set_inline_handler(event, handler)
      previous = @inline_handlers[event]
      remove_event_listener(event, previous) if previous
      if handler.nil?
        @inline_handlers.delete(event)
      else
        add_event_listener(event, handler)
        @inline_handlers[event] = handler
      end
    end

    def invoke(callback, args)
      if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", args)
      elsif callback.respond_to?(:call)
        callback.call(*args)
      end
    end
  end
end
