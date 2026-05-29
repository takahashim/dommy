# frozen_string_literal: true

module Dommy
  # `EventSource` (Server-Sent Events). Like `WebSocket`, dommy
  # provides simulation seams instead of network IO:
  #
  #   es.__test_simulate_open__
  #   es.__test_simulate_message__(data, event: "msg", id: "1")
  #   es.__test_simulate_error__
  #
  # Auto-opens on a microtask after construction, mirroring real
  # browser behavior.
  #
  # Spec: https://html.spec.whatwg.org/multipage/server-sent-events.html
  class EventSource
    include EventTarget

    CONNECTING = 0
    OPEN = 1
    CLOSED = 2

    INLINE_HANDLERS = %w[open message error].freeze

    attr_reader :url, :ready_state, :with_credentials

    def initialize(window, url, options = nil)
      @window = window
      @url = url.to_s
      @ready_state = CONNECTING
      opts = options.is_a?(Hash) ? options : {}
      @with_credentials = !!(opts["withCredentials"] || opts[:withCredentials])
      @inline_handlers = {}

      @window.scheduler.queue_microtask(proc { __test_simulate_open__ })
    end

    def close
      @ready_state = CLOSED
      nil
    end

    # --- Test seams ------------------------------------------------

    def __test_simulate_open__
      return if @ready_state != CONNECTING

      @ready_state = OPEN
      dispatch_event(Event.new("open"))
    end

    def __test_simulate_message__(data, event: "message", id: nil, retry_ms: nil)
      return if @ready_state != OPEN

      payload = {"data" => data.to_s}
      payload["lastEventId"] = id.to_s if id
      payload["retry"] = retry_ms.to_i if retry_ms
      dispatch_event(MessageEvent.new(event.to_s, payload))
    end

    def __test_simulate_error__
      dispatch_event(Event.new("error"))
    end

    # --- JS bridge -------------------------------------------------

    def __js_get__(key)
      case key
      when "url"
        @url
      when "readyState"
        @ready_state
      when "withCredentials"
        @with_credentials
      when "CONNECTING"
        CONNECTING
      when "OPEN"
        OPEN
      when "CLOSED"
        CLOSED
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
      when "close"
        close
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
  end
end
