# frozen_string_literal: true

module Dommy
  # `MessageChannel` — creates a pair of `MessagePort`s connected to
  # each other. `port1.postMessage(x)` queues a microtask that fires
  # a `message` event on `port2`, and vice versa.
  #
  # Spec: https://html.spec.whatwg.org/multipage/web-messaging.html
  class MessageChannel
    attr_reader :port1, :port2

    def initialize(window)
      @port1 = MessagePort.new(window)
      @port2 = MessagePort.new(window)
      @port1.__internal_entangle__(@port2)
      @port2.__internal_entangle__(@port1)
    end

    def __js_get__(key)
      case key
      when "port1"
        @port1
      when "port2"
        @port2
      else
        Bridge::ABSENT
      end
    end
  end

  # `MessagePort` — one end of a MessageChannel. `postMessage(value)`
  # dispatches a `MessageEvent` on the entangled port asynchronously.
  class MessagePort
    include EventTarget

    def initialize(window)
      @window = window
      @entangled = nil
      @onmessage = nil
      @started = false
      @pending = []
    end

    def __internal_entangle__(other)
      @entangled = other
    end

    def post_message(data)
      port = @entangled
      return unless port

      @window.scheduler.queue_microtask(
        proc do
          evt = MessageEvent.new("message", "data" => Dommy.structured_clone(data))
          if port.__internal_started?
            port.dispatch_event(evt)
          else
            port.__internal_enqueue__(evt)
          end
        end
      )

      nil
    end

    alias postMessage post_message

    def start
      @started = true
      flush = @pending
      @pending = []
      flush.each { |evt| dispatch_event(evt) }
      nil
    end

    def close
      @entangled = nil
      nil
    end

    def __internal_started?
      @started || !@inline_message_handler.nil?
    end

    def __internal_enqueue__(event)
      @pending << event
    end

    def __js_get__(key)
      case key
      when "onmessage"
        @onmessage
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "onmessage"
        # Setting onmessage implicitly starts the port per spec.
        remove_event_listener("message", @onmessage) if @onmessage
        @onmessage = value
        @inline_message_handler = value
        add_event_listener("message", value) if value
        start if value
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[postMessage start close addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "postMessage"
        post_message(args[0])
      when "start"
        start
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

  # `MessageEvent` — payload of `message` events on MessagePort /
  # BroadcastChannel / WebSocket / EventSource.
  class MessageEvent < Event
    def initialize(type, init = nil)
      super
      @data = read_init(init, "data")
      @origin = (read_init(init, "origin") || "").to_s
      @last_event_id = (read_init(init, "lastEventId") || "").to_s
      @source = read_init(init, "source")
      @ports = read_init(init, "ports") || []
    end

    attr_reader :data, :origin, :last_event_id, :source, :ports

    def __js_get__(key)
      case key
      when "data"
        @data
      when "origin"
        @origin
      when "lastEventId"
        @last_event_id
      when "source"
        @source
      when "ports"
        @ports
      else
        super
      end
    end

    js_methods %w[initMessageEvent]
    def __js_call__(method, args)
      case method
      when "initMessageEvent"
        # Deprecated initMessageEvent(type, bubbles, cancelable, data, origin,
        # lastEventId, source, ports); a no-op while the event is dispatching.
        raise Bridge::TypeError, "initMessageEvent requires a type argument" if args.empty?

        unless @dispatch_flag
          init_event(args[0], args[1], args[2])
          @data = args[3]
          @origin = (args[4] || "").to_s
          @last_event_id = (args[5] || "").to_s
          @source = args[6]
          @ports = args[7] || []
        end
        nil
      else
        super
      end
    end
  end

  # `BroadcastChannel` — same-origin pub/sub. Dommy keeps a per-window
  # channel registry; sending posts to all other peers on the same
  # name within the same Window.
  class BroadcastChannel
    include EventTarget

    @@registries = Hash.new { |h, w| h[w] = Hash.new { |c, n| c[n] = [] } }

    attr_reader :name

    def initialize(window, name)
      @window = window
      @name = name.to_s
      @closed = false
      @onmessage = nil
      @@registries[window][@name] << self
    end

    def post_message(data)
      return if @closed

      peers = @@registries[@window][@name].reject { |p| p.equal?(self) || p.closed? }
      cloned = Dommy.structured_clone(data)
      peers.each do |peer|
        @window.scheduler.queue_microtask(
          proc do
            peer.dispatch_event(MessageEvent.new("message", "data" => cloned))
          end
        )
      end

      nil
    end

    alias postMessage post_message

    def close
      return if @closed

      @closed = true
      @@registries[@window][@name].delete(self)
      nil
    end

    def closed?
      @closed
    end

    def __js_get__(key)
      case key
      when "name"
        @name
      when "onmessage"
        @onmessage
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "onmessage"
        remove_event_listener("message", @onmessage) if @onmessage
        @onmessage = value
        add_event_listener("message", value) if value
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[postMessage close addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "postMessage"
        post_message(args[0])
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
