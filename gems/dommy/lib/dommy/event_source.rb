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
    include Internal::EventHandlers::IdlAttributeBridge

    CONNECTING = 0
    OPEN = 1
    CLOSED = 2

    attr_reader :url, :ready_state, :with_credentials

    def initialize(window, url, options = nil)
      @window = window
      @url = url.to_s
      @ready_state = CONNECTING
      opts = options.is_a?(Hash) ? options : {}
      @with_credentials = !!(opts["withCredentials"] || opts[:withCredentials])

      # A host-installed connector (Dommy::Rack wires real in-process streams
      # through it) owns the connection when it returns a transport; otherwise
      # fall back to the simulation stub, which auto-opens via microtask.
      connector = window.respond_to?(:event_source_connector) ? window.event_source_connector : nil
      @transport = connector&.call(self, @url, @with_credentials)
      return if @transport

      @window.scheduler.queue_microtask(proc { __test_simulate_open__ })
    end

    def close
      @ready_state = CLOSED
      @transport&.close
      nil
    end

    # --- Transport callbacks ---------------------------------------
    # A connector-provided transport reports the stream's lifecycle through
    # these, ON THE PAGE THREAD (a threaded transport marshals via
    # scheduler.post_external). They share the state machine with the test
    # seams so stub-driven and transport-driven streams behave identically.

    def __internal_transport_open__
      __test_simulate_open__
    end

    def __internal_transport_message__(data, event: "message", id: nil)
      return if @ready_state != OPEN

      payload = {"data" => data.to_s}
      payload["lastEventId"] = id.to_s if id
      dispatch_event(MessageEvent.new(event.to_s, payload))
    end

    # A stream error: an EventSource fires `error` and would reconnect;
    # reconnection is not simulated.
    def __internal_transport_error__
      __test_simulate_error__ unless @ready_state == CLOSED
    end

    # The server ended the stream. An EventSource has no `close` event: it
    # fires `error` and reconnects, so that is what a closed transport reports.
    def __internal_transport_closed__
      return if @ready_state == CLOSED

      @ready_state = CLOSED
      dispatch_event(Event.new("error"))
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
        event_handler_idl_attribute?(key) ? event_handler_idl_get(key) : Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      return Bridge::UNHANDLED unless event_handler_idl_attribute?(key)

      event_handler_idl_set(key, value)
    end

    include Bridge::Methods
    js_methods %w[close addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "close"
        close
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end

  end
end
