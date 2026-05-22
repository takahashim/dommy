# frozen_string_literal: true

module Dommy
  # `WebSocket` polyfill. Real implementations open a TCP-then-frame
  # connection; dommy exposes an in-memory transport tests drive via
  # the `__*` seams:
  #
  #   ws.__simulate_open__               — fires `open`
  #   ws.__simulate_message__(data)      — fires `message`
  #   ws.__simulate_close__(code, reason) — fires `close`
  #   ws.__simulate_error__              — fires `error`
  #   ws.__sent_messages__               — array of sent payloads
  #
  # By default a `new WebSocket(url)` auto-opens via microtask so the
  # common pattern (`ws.onopen = ...; ws.send(...)`) works without
  # extra setup.
  #
  # Spec: https://websockets.spec.whatwg.org/
  class WebSocket
    include EventTarget

    CONNECTING = 0
    OPEN = 1
    CLOSING = 2
    CLOSED = 3

    INLINE_HANDLERS = %w[open message close error].freeze

    attr_reader :url, :protocol, :ready_state, :buffered_amount, :extensions
    attr_accessor :binary_type

    def initialize(window, url, protocols = nil)
      @window = window
      @url = url.to_s
      @ready_state = CONNECTING
      @buffered_amount = 0
      @extensions = ""
      @binary_type = "blob"
      @protocol = Array(protocols).first.to_s
      @sent_messages = []
      @inline_handlers = {}

      # Auto-open via microtask unless tests disable.
      auto_open = window.globals["__ws_auto_open__"]
      @window.scheduler.queue_microtask(proc { __simulate_open__ }) unless auto_open == false
    end

    def send(data)
      raise Error, "WebSocket not OPEN" if @ready_state != OPEN

      @sent_messages << data
      nil
    end

    def close(code = 1000, reason = "")
      return if @ready_state == CLOSED || @ready_state == CLOSING

      @ready_state = CLOSING
      @window.scheduler.queue_microtask(proc { __simulate_close__(code, reason) })
      nil
    end

    # --- Test seams ------------------------------------------------

    def __sent_messages__
      @sent_messages.dup
    end

    def __simulate_open__
      return if @ready_state != CONNECTING

      @ready_state = OPEN
      dispatch_event(Event.new("open"))
    end

    def __simulate_message__(data)
      return if @ready_state != OPEN

      dispatch_event(MessageEvent.new("message", "data" => data))
    end

    def __simulate_close__(code = 1000, reason = "", was_clean: true)
      @ready_state = CLOSED
      dispatch_event(
        CloseEvent.new(
          "close",
          "code" => code,
          "reason" => reason,
          "wasClean" => was_clean
        )
      )
    end

    def __simulate_error__
      dispatch_event(Event.new("error"))
    end

    # --- JS bridge -------------------------------------------------

    def __js_get__(key)
      case key
      when "url"
        @url
      when "readyState"
        @ready_state
      when "bufferedAmount"
        @buffered_amount
      when "extensions"
        @extensions
      when "protocol"
        @protocol
      when "binaryType"
        @binary_type
      when "CONNECTING"
        CONNECTING
      when "OPEN"
        OPEN
      when "CLOSING"
        CLOSING
      when "CLOSED"
        CLOSED
      else
        @inline_handlers[inline_event_for(key)]
      end
    end

    def __js_set__(key, value)
      case key
      when "binaryType"
        @binary_type = value.to_s
      else
        event = inline_event_for(key)
        set_inline_handler(event, value) if event
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "send"
        send(args[0])
      when "close"
        close(args[0] || 1000, args[1] || "")
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __event_parent__
      nil
    end

    class Error < StandardError
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

  # `CloseEvent` — payload for the `close` event on WebSocket.
  class CloseEvent < Event
    def initialize(type, init = nil)
      super
      @code = (read_init(init, "code") || 1005).to_i
      @reason = (read_init(init, "reason") || "").to_s
      @was_clean = !!read_init(init, "wasClean")
    end

    attr_reader :code, :reason, :was_clean

    def __js_get__(key)
      case key
      when "code"
        @code
      when "reason"
        @reason
      when "wasClean"
        @was_clean
      else
        super
      end
    end
  end
end
