# frozen_string_literal: true

module Dommy
  # `MessageChannel` — creates a pair of `MessagePort`s connected to
  # each other. `port1.postMessage(x)` queues a TASK (the "post message" task
  # source, not a microtask) that fires a `message` event on `port2`, and vice
  # versa — so the message is delivered in a later event-loop turn, after the
  # current task's microtask checkpoint. React's scheduler relies on this to
  # yield as a macrotask.
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
  # serializes the value and queues its delivery as a `MessageEvent` on the
  # entangled port, in a later task.
  #
  # A port is transferable: transferring it (`postMessage(x, [port])`) detaches
  # it and hands its entanglement and its queued messages to the new port the
  # receiver gets (see #__internal_transfer__).
  class MessagePort
    include EventTarget

    def initialize(window)
      @window = window
      @entangled = nil
      @onmessage = nil
      @started = false
      @pending = []
      @detached = false
      @transferred_to = nil
    end

    # Entangle this port with `other` (one-sided; the caller pairs them).
    def __internal_entangle__(other)
      @entangled = other
    end

    def __internal_entangled__ = @entangled

    # Internal state the JS-side postMessage reads (see host_bridge.rb
    # __rb_host_state): the entangled port, to tell a doomed post.
    def __internal_state__(name)
      @entangled if name == "entangled"
    end

    # The port `message` from this port is delivered to: `port` itself, or the
    # port it was transferred to (its message queue moved along with it).
    def __internal_final_port__
      port = self
      port = port.__internal_transferred_to__ while port.__internal_transferred_to__
      port
    end

    def __internal_transferred_to__ = @transferred_to

    # [[Detached]]: true once the port was transferred or closed.
    def __internal_detached__? = @detached

    # The transfer steps and transfer-receiving steps at once (the receiving
    # realm is this one): a new port takes over this one's message queue
    # (disabled until started) and its entanglement, and this one is detached.
    def __internal_transfer__
      raise DOMException::DataCloneError, "A detached MessagePort could not be transferred" if @detached

      receiver = MessagePort.new(@window)
      @detached = true
      @transferred_to = receiver
      receiver.__internal_take_queue__(@pending)
      @pending = []
      remote = @entangled
      @entangled = nil
      if remote
        remote.__internal_entangle__(receiver)
        receiver.__internal_entangle__(remote)
      end
      receiver
    end

    def __internal_take_queue__(pending)
      @pending.concat(pending)
    end

    # The message port post message steps. `doomed` is true when the transfer
    # list held the target port itself (the channel is lost; nothing is sent).
    def post_message(message, doomed: false)
      serialized = Dommy.structured_serialize(message)
      target = @entangled
      return nil if target.nil? || doomed

      # The "post message" task source — a task, NOT a microtask, so delivery
      # happens in a later event-loop turn (after the current task's microtask
      # checkpoint), matching browsers.
      @window.scheduler.set_timeout(proc { target.__internal_final_port__.__internal_receive__(serialized) }, 0)
      nil
    end

    alias postMessage post_message

    # A task from the port message queue. The queue holds the messages in
    # order; while it is enabled each task delivers the oldest one, so a message
    # held back before start() still arrives before a later one.
    def __internal_receive__(serialized)
      @pending << serialized
      deliver(@pending.shift) if __internal_started?
    end

    # start(): enable the port message queue. The held messages become tasks
    # (delivered in later turns, not inside this call).
    def start
      return nil if @started

      @started = true
      @pending.size.times do
        @window.scheduler.set_timeout(proc { deliver(@pending.shift) unless @pending.empty? }, 0)
      end
      nil
    end

    # close(): detach this port and disentangle it from its twin.
    def close
      @detached = true
      remote = @entangled
      @entangled = nil
      remote&.__internal_disentangle__(self)
      nil
    end

    def __internal_disentangle__(port)
      @entangled = nil if @entangled.equal?(port)
    end

    def __internal_started?
      @started || !@inline_message_handler.nil?
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
        post_message(args[0], doomed: args[1] == true)
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

    private

    # Deserialize and fire `message` (or `messageerror` when the value cannot
    # be rebuilt here).
    def deliver(serialized)
      begin
        data, ports = serialized.deserialize_with_transfer
      rescue DOMException::DataCloneError
        dispatch_event(MessageEvent.new("messageerror").__internal_mark_trusted__)
        return
      ensure
        serialized.release if serialized.respond_to?(:release)
      end
      dispatch_event(MessageEvent.new("message", "data" => data, "ports" => ports).__internal_mark_trusted__)
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

    # postMessage(message): serialize once, then queue a task per other open
    # channel of the same name that deserializes its own copy (a closed
    # destination by then is skipped; one that cannot deserialize gets
    # `messageerror`).
    def post_message(data)
      raise DOMException::InvalidStateError, "The BroadcastChannel is closed" if @closed

      serialized = Dommy.structured_serialize(data)
      origin = @window.respond_to?(:origin) ? @window.origin.to_s : ""
      peers = @@registries[@window][@name].reject { |p| p.equal?(self) || p.closed? }
      peers.each do |peer|
        # A task (post message task source), not a microtask — delivered in a
        # later turn like a real BroadcastChannel.
        @window.scheduler.set_timeout(proc { peer.__internal_receive__(serialized, origin) }, 0)
      end

      nil
    end

    def __internal_receive__(serialized, origin)
      return if @closed

      begin
        data = serialized.deserialize
      rescue DOMException::DataCloneError
        dispatch_event(MessageEvent.new("messageerror", "origin" => origin).__internal_mark_trusted__)
        return
      end
      dispatch_event(MessageEvent.new("message", "data" => data, "origin" => origin).__internal_mark_trusted__)
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

    # Internal state the JS-side postMessage reads before serializing.
    def __internal_state__(name)
      @closed if name == "closed"
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
