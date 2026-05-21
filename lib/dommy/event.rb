# frozen_string_literal: true

module Dommy
  # Note: `Callback` and `Constructor` live in `Dommy::Bridge::*` —
  # they're bridge-adapter classes, not part of the public DOM
  # surface.

  module EventTarget
    def add_event_listener(type, listener = nil, options = nil, &block)
      cb = listener || block
      return nil if type.nil? || cb.nil?

      list = listeners_for(type.to_s)
      # Per spec, the same listener (by identity) registered on the
      # same type is silently deduplicated.
      return nil if list.any? { |entry| entry.listener.equal?(cb) }

      list << Listener.new(cb, options)

      # `{ signal: AbortSignal }` — when the signal aborts, auto-
      # remove the listener. Per spec, if the signal is already aborted
      # the listener must not be registered at all.
      signal = options.is_a?(Hash) ? (options["signal"] || options[:signal]) : nil
      if signal.respond_to?(:__js_get__)
        if signal.__js_get__("aborted")
          remove_event_listener(type, cb)
        else
          target = self
          signal.__js_call__(
            "addEventListener",
            [
              "abort",
              proc {
                target.remove_event_listener(type, cb)
              }
            ]
          )
        end
      end

      nil
    end

    def remove_event_listener(type, listener)
      return nil if type.nil? || listener.nil?

      listeners_for(type.to_s).reject! { |entry| entry.listener.equal?(listener) }
      nil
    end

    def dispatch_event(event)
      return true if event.nil?

      # Per spec, dispatchEvent must receive an Event instance.
      raise TypeError, "dispatchEvent requires an Event, got #{event.class}" unless event.is_a?(Event)

      event.__prepare_for_dispatch__(self)
      path = if event.bubbles?
        event.__js_get__("composed") ? composed_bubble_path(event) : event_bubble_path
      else
        [self]
      end

      event.__record_path__(path) if event.respond_to?(:__record_path__)
      path.each do |target|
        event.__set_current_target__(target)
        target.__deliver_event__(event)
        break if event.propagation_stopped?
      end

      !event.default_prevented?
    end

    def __deliver_event__(event)
      listeners = listeners_for(event.type).dup
      listeners.each do |entry|
        invoke_listener(entry.listener, event)
        if entry.once?
          listeners_for(event.type).reject! { |candidate| candidate.listener.equal?(entry.listener) }
        end

        break if event.immediate_propagation_stopped?
      end

      nil
    end

    private

    Listener = Struct.new(:listener, :options) do
      def once?
        case options
        when Hash
          options["once"] || options[:once]
        else
          false
        end
      end
    end

    def listeners_for(type)
      @event_listeners ||= Hash.new { |h, k| h[k] = [] }
      @event_listeners[type]
    end

    def event_bubble_path
      path = [self]
      current = self
      while (current = current.send(:__event_parent__))
        path << current
      end

      path
    end

    # Build the propagation path with optional shadow-boundary
    # crossing. When the in-flight event has `composed: true`, the
    # walk continues from a ShadowRoot to its host; otherwise it
    # stops at the shadow boundary (nil from `__event_parent__`).
    def composed_bubble_path(event)
      path = [self]
      current = self
      loop do
        nxt = current.send(:__event_parent__)
        if nxt.nil? && event.respond_to?(:__js_get__) && event.__js_get__("composed")
          # Try to cross a shadow boundary
          if current.is_a?(ShadowRoot)
            # If current is a ShadowRoot, jump to its host
            nxt = current.host
          else
            # If current is a node inside a ShadowRoot, find and jump to host
            sr = enclosing_shadow_root_of(current)
            break unless sr

            nxt = sr.host
          end
        end

        break unless nxt

        path << nxt
        current = nxt
      end

      path
    end

    private

    def enclosing_shadow_root_of(target)
      return nil unless target.respond_to?(:__node__)

      doc = target.instance_variable_get(:@document)
      return nil unless doc && doc.respond_to?(:__shadow_root_containing__)

      doc.__shadow_root_containing__(target.__node__)
    end

    public

    def invoke_listener(listener, event)
      # DOM spec: a listener can be (a) a function, or (b) an object
      # with a `handleEvent` method. Both Ruby and JS-bridged callables
      # are supported.
      if listener.respond_to?(:handle_event)
        listener.handle_event(event)
      elsif listener.respond_to?(:call) && !listener.is_a?(Module)
        listener.call(event)
      elsif listener.respond_to?(:__js_call__)
        # Prefer handleEvent if the bridge object advertises it; fall
        # back to call. We can't introspect on the JS side, so we just
        # try call (the common case for JS.callback {}).
        listener.__js_call__("call", [event])
      end
    end
  end

  class StandaloneEventTarget
    include EventTarget

    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      else
        nil
      end
    end

    def __event_parent__
      nil
    end
  end

  class Event
    def initialize(type, init = nil)
      @type = type.to_s
      @bubbles = !!read_init(init, "bubbles")
      @cancelable = !!read_init(init, "cancelable")
      @composed = !!read_init(init, "composed")
      @default_prevented = false
      @propagation_stopped = false
      @immediate_propagation_stopped = false
      @target = nil
      @current_target = nil
      @composed_path = []
      # `timeStamp` is the high-resolution timestamp at construction
      # in ms (browser uses performance.now). We use monotonic time
      # for determinism across spec runs.
      @time_stamp = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0)
    end

    attr_reader :type

    def bubbles?
      @bubbles
    end

    def default_prevented?
      @default_prevented
    end

    def propagation_stopped?
      @propagation_stopped
    end

    def immediate_propagation_stopped?
      @immediate_propagation_stopped
    end

    def __prepare_for_dispatch__(target)
      @target ||= target
    end

    def __set_current_target__(target)
      @current_target = target
    end

    def __js_get__(key)
      case key
      when "type"
        @type
      when "bubbles"
        @bubbles
      when "cancelable"
        @cancelable
      when "composed"
        @composed
      when "defaultPrevented"
        @default_prevented
      when "target"
        @target
      when "currentTarget"
        @current_target
      when "timeStamp"
        @time_stamp
      when "cancelBubble"
        @propagation_stopped
      when "eventPhase"
        event_phase
      end
    end

    def __js_set__(key, value)
      case key
      when "cancelBubble"
        # Setting to truthy stops propagation; spec quirk that
        # `cancelBubble = false` does NOT un-stop (browser observation).
        @propagation_stopped = true if value
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "preventDefault"
        @default_prevented = true if @cancelable
        nil
      when "stopPropagation"
        @propagation_stopped = true
        nil
      when "stopImmediatePropagation"
        @propagation_stopped = true
        @immediate_propagation_stopped = true
        nil
      when "composedPath"
        @composed_path.dup
      when "initEvent"
        init_event(args[0], args[1], args[2])
      end
    end

    # Deprecated `Event#initEvent(type, bubbles, cancelable)` — older
    # browsers used `document.createEvent("Event").initEvent(...)`.
    # Resets internal flags as a side effect.
    def init_event(type, bubbles = false, cancelable = false)
      @type = type.to_s
      @bubbles = !!bubbles
      @cancelable = !!cancelable
      @default_prevented = false
      @propagation_stopped = false
      @immediate_propagation_stopped = false
      nil
    end

    # Filled in by EventTarget#dispatch_event as the event walks the
    # bubble path so `composedPath()` returns the right list.
    #
    # Per spec, `load` events do not propagate to the Window when
    # composed paths are computed (resource-finished signal stays at
    # the target).
    def __record_path__(targets)
      @composed_path = if @type == "load"
        targets.reject { |t| t.is_a?(Window) }
      else
        targets
      end
    end

    private

    def event_phase
      # 0 = NONE (default), 2 = AT_TARGET, 3 = BUBBLING_PHASE. We don't
      # implement capturing (phase 1) by design.
      return 0 if @current_target.nil?
      return 2 if @current_target.equal?(@target)

      3
    end

    public

    private

    def read_init(init, key)
      case init
      when Hash
        init[key] || init[key.to_sym]
      else
        init.respond_to?(:__js_get__) ? init.__js_get__(key) : nil
      end
    end
  end

  class CustomEvent < Event
    def initialize(type, init = nil)
      super
      @detail = read_init(init, "detail")
    end

    def __js_get__(key)
      return @detail if key == "detail"

      super
    end
  end

  class MouseEvent < Event
    def initialize(type, init = nil)
      super
      @button = read_init(init, "button") || 0
      @ctrl_key = !!read_init(init, "ctrlKey")
      @shift_key = !!read_init(init, "shiftKey")
      @alt_key = !!read_init(init, "altKey")
      @meta_key = !!read_init(init, "metaKey")
      @client_x = read_init(init, "clientX") || 0
      @client_y = read_init(init, "clientY") || 0
    end

    def __js_get__(key)
      case key
      when "button"
        @button
      when "ctrlKey"
        @ctrl_key
      when "shiftKey"
        @shift_key
      when "altKey"
        @alt_key
      when "metaKey"
        @meta_key
      when "clientX"
        @client_x
      when "clientY"
        @client_y
      else
        super
      end
    end
  end

  # `DragEvent` — fired during drag-and-drop with a `dataTransfer`
  # payload. Inherits from MouseEvent so coordinates / modifier keys
  # are available alongside the dragged data.
  class DragEvent < MouseEvent
    def initialize(type, init = nil)
      super
      @data_transfer = read_init(init, "dataTransfer")
    end

    attr_reader :data_transfer

    def __js_get__(key)
      case key
      when "dataTransfer"
        @data_transfer
      else
        super
      end
    end
  end

  class KeyboardEvent < Event
    def initialize(type, init = nil)
      super
      @key = read_init(init, "key").to_s
      @ctrl_key = !!read_init(init, "ctrlKey")
      @shift_key = !!read_init(init, "shiftKey")
      @alt_key = !!read_init(init, "altKey")
      @meta_key = !!read_init(init, "metaKey")
    end

    def __js_get__(key)
      case key
      when "key"
        @key
      when "ctrlKey"
        @ctrl_key
      when "shiftKey"
        @shift_key
      when "altKey"
        @alt_key
      when "metaKey"
        @meta_key
      else
        super
      end
    end
  end

  # `AbortController` + `AbortSignal` subset. Signal fires an
  # "abort" event and flips `[:aborted]` to true when the controller's
  # `abort()` is called; otherwise it stays inert.
  class AbortSignal
    include EventTarget

    # Spec: `AbortSignal.abort(reason?)` returns a fresh, pre-aborted
    # signal. Convenient for APIs that need an already-cancelled token.
    def self.abort(reason = nil)
      signal = new
      signal.__mark_aborted__(reason)
      signal
    end

    # Spec: `AbortSignal.timeout(ms)` returns a signal that aborts
    # itself after `ms` milliseconds with a `TimeoutError` reason.
    # Without a Window/scheduler we fall back to a Thread-based timer
    # so the signal works in vanilla CRuby; embedders that want
    # microtask integration can pass a window via `__schedule_via__`.
    def self.timeout(ms, scheduler: nil)
      signal = new
      reason = DOMException::TimeoutError.new("operation timed out")
      if scheduler
        scheduler.set_timeout(proc { signal.__mark_aborted__(reason) }, ms.to_i)
      else
        signal.__schedule_thread_timeout__(ms.to_i, reason)
      end

      signal
    end

    # Spec: `AbortSignal.any([sig, ...])` returns a composite signal
    # that aborts as soon as any of the inputs aborts. If any input
    # is already aborted, the returned signal is pre-aborted with
    # that input's reason.
    def self.any(signals)
      composite = new
      list = Array(signals).select { |s| s.is_a?(AbortSignal) }
      already = list.find(&:aborted?)
      if already
        composite.__mark_aborted__(already.reason)
        return composite
      end

      list.each do |sig|
        sig.add_event_listener("abort", proc { composite.__mark_aborted__(sig.reason) })
      end

      composite
    end

    def initialize
      @aborted = false
      @reason = nil
    end

    # Background-thread timeout used by `AbortSignal.timeout` when no
    # scheduler is provided. Kept package-private; tests can also
    # drive the abort manually via `__mark_aborted__`.
    def __schedule_thread_timeout__(ms, reason)
      Thread.new do
        sleep(ms.to_f / 1000.0)
        __mark_aborted__(reason)
      end

      nil
    end

    def aborted?
      @aborted
    end

    def reason
      @reason
    end

    # Spec: throws `signal.reason` if aborted, otherwise no-op. Used by
    # consumer code that polls before doing async work.
    def throw_if_aborted
      return unless @aborted

      raise @reason.is_a?(Exception) ? @reason : RuntimeError.new(@reason.to_s)
    end

    alias throwIfAborted throw_if_aborted

    def __js_get__(key)
      case key
      when "aborted"
        @aborted
      when "reason"
        @reason
      end
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "throwIfAborted"
        throw_if_aborted
      end
    end

    def __mark_aborted__(reason = nil)
      return if @aborted

      @aborted = true
      @reason = reason
      dispatch_event(Event.new("abort", "bubbles" => false, "cancelable" => false))
    end
  end

  class AbortController
    attr_reader :signal

    def initialize
      @signal = AbortSignal.new
    end

    def __js_get__(key)
      @signal if key == "signal"
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "abort"
        @signal.__mark_aborted__(args[0])
      end
    end
  end
end
