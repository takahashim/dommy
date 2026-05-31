# frozen_string_literal: true

module Dommy
  # `WebSocket` polyfill. Real implementations open a TCP-then-frame
  # connection; dommy exposes an in-memory transport tests drive via
  # the `__*` seams:
  #
  #   ws.__test_simulate_open__               — fires `open`
  #   ws.__test_simulate_message__(data)      — fires `message`
  #   ws.__test_simulate_close__(code, reason) — fires `close`
  #   ws.__test_simulate_error__              — fires `error`
  #   ws.__test_sent_messages__               — array of sent payloads
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
    attr_reader :binary_type

    def initialize(window, url, protocols = nil)
      @window = window
      @url = url.to_s
      @ready_state = CONNECTING
      @buffered_amount = 0
      @extensions = ""
      @binary_type = "blob"
      # The subprotocol stays "" until the server selects one at the handshake;
      # remember what was requested and adopt the first on open.
      @requested_protocols = Array(protocols).flatten.map(&:to_s)
      @protocol = ""
      @sent_messages = []
      @inline_handlers = {}

      # Auto-open via microtask unless tests disable.
      auto_open = window.globals["__ws_auto_open__"]
      @window.scheduler.queue_microtask(proc { __test_simulate_open__ }) unless auto_open == false
    end

    # binaryType is an enumerated attribute: only "blob"/"arraybuffer" are
    # accepted, any other assignment is ignored (per WebIDL enum reflection).
    def binary_type=(value)
      v = value.to_s
      @binary_type = v if %w[blob arraybuffer].include?(v)
    end

    def send(data)
      # send() before the connection opens is an InvalidStateError (a
      # DOMException), not a bare Ruby error.
      raise DOMException::InvalidStateError, "WebSocket is not open" if @ready_state == CONNECTING
      return if @ready_state != OPEN # CLOSING/CLOSED silently discard (buffered)

      @sent_messages << data
      nil
    end

    # close([code[, reason]]): code must be 1000 or in 3000–4999, and the UTF-8
    # reason must be ≤ 123 bytes, else throw — matching the WebSocket spec.
    def close(code = nil, reason = nil)
      unless code.nil?
        c = code.to_i
        unless c == 1000 || c.between?(3000, 4999)
          raise DOMException::InvalidAccessError, "The close code must be 1000 or in 3000-4999, got #{c}."
        end
      end
      if reason && reason.to_s.bytesize > 123
        raise DOMException::SyntaxError, "The close reason must not exceed 123 UTF-8 bytes."
      end
      return if @ready_state == CLOSED || @ready_state == CLOSING

      @ready_state = CLOSING
      final_code = code.nil? ? 1005 : code.to_i
      final_reason = reason.to_s
      @window.scheduler.queue_microtask(proc { __test_simulate_close__(final_code, final_reason) })
      nil
    end

    # --- Test seams ------------------------------------------------

    def __test_sent_messages__
      @sent_messages.dup
    end

    def __test_simulate_open__
      return if @ready_state != CONNECTING

      @ready_state = OPEN
      # The handshake "selects" the first requested subprotocol.
      @protocol = @requested_protocols.first || ""
      dispatch_event(Event.new("open"))
    end

    def __test_simulate_message__(data)
      return if @ready_state != OPEN

      dispatch_event(MessageEvent.new("message", "data" => data))
    end

    def __test_simulate_close__(code = 1000, reason = "", was_clean: true)
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
        self.binary_type = value
      else
        event = inline_event_for(key)
        set_inline_handler(event, value) if event
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[send close addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "send"
        send(args[0])
      when "close"
        close(args[0] || 1000, args[1] || "")
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
