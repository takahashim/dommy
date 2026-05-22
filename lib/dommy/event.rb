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

  # `InputEvent` — fired by `input` / `beforeinput`. Carries `data`
  # (the inserted text, if any) and `inputType` (insertText,
  # deleteContentBackward, etc.).
  class InputEvent < Event
    def initialize(type, init = nil)
      super
      @data = read_init(init, "data")
      @input_type = (read_init(init, "inputType") || "").to_s
      @is_composing = !!read_init(init, "isComposing")
    end

    def __js_get__(key)
      case key
      when "data"
        @data
      when "inputType"
        @input_type
      when "isComposing"
        @is_composing
      else
        super
      end
    end
  end

  # `PointerEvent` — pointer (mouse / touch / pen) unified events.
  # Inherits from MouseEvent for coords / modifier keys; adds
  # pointerId, pointerType, pressure, width, height, etc.
  class PointerEvent < MouseEvent
    def initialize(type, init = nil)
      super
      @pointer_id = (read_init(init, "pointerId") || 0).to_i
      @pointer_type = (read_init(init, "pointerType") || "mouse").to_s
      @pressure = (read_init(init, "pressure") || 0).to_f
      @tangential_pressure = (read_init(init, "tangentialPressure") || 0).to_f
      @width = (read_init(init, "width") || 1).to_f
      @height = (read_init(init, "height") || 1).to_f
      @tilt_x = (read_init(init, "tiltX") || 0).to_i
      @tilt_y = (read_init(init, "tiltY") || 0).to_i
      @twist = (read_init(init, "twist") || 0).to_i
      @is_primary = !!read_init(init, "isPrimary")
    end

    def __js_get__(key)
      case key
      when "pointerId"
        @pointer_id
      when "pointerType"
        @pointer_type
      when "pressure"
        @pressure
      when "tangentialPressure"
        @tangential_pressure
      when "width"
        @width
      when "height"
        @height
      when "tiltX"
        @tilt_x
      when "tiltY"
        @tilt_y
      when "twist"
        @twist
      when "isPrimary"
        @is_primary
      else
        super
      end
    end
  end

  # `ProgressEvent` — fired during long-running operations (XHR,
  # fetch upload/download progress). Carries `loaded` / `total` /
  # `lengthComputable`.
  class ProgressEvent < Event
    def initialize(type, init = nil)
      super
      @loaded = (read_init(init, "loaded") || 0).to_i
      @total = (read_init(init, "total") || 0).to_i
      @length_computable = !!read_init(init, "lengthComputable")
    end

    def __js_get__(key)
      case key
      when "loaded"
        @loaded
      when "total"
        @total
      when "lengthComputable"
        @length_computable
      else
        super
      end
    end
  end

  # `Touch` — a single touch point on a touch-capable surface.
  # Constructed by tests; tied to a target element and coordinate set.
  #
  # Spec: https://w3c.github.io/touch-events/#touch-interface
  class Touch
    attr_reader(
      :identifier,
      :target,
      :client_x,
      :client_y,
      :page_x,
      :page_y,
      :screen_x,
      :screen_y,
      :radius_x,
      :radius_y,
      :rotation_angle,
      :force
    )

    def initialize(init = {})
      @identifier = (init["identifier"] || init[:identifier] || 0).to_i
      @target = init["target"] || init[:target]
      @client_x = (init["clientX"] || init[:clientX] || 0).to_f
      @client_y = (init["clientY"] || init[:clientY] || 0).to_f
      @page_x = (init["pageX"] || init[:pageX] || @client_x).to_f
      @page_y = (init["pageY"] || init[:pageY] || @client_y).to_f
      @screen_x = (init["screenX"] || init[:screenX] || @client_x).to_f
      @screen_y = (init["screenY"] || init[:screenY] || @client_y).to_f
      @radius_x = (init["radiusX"] || init[:radiusX] || 0).to_f
      @radius_y = (init["radiusY"] || init[:radiusY] || 0).to_f
      @rotation_angle = (init["rotationAngle"] || init[:rotationAngle] || 0).to_f
      @force = (init["force"] || init[:force] || 0).to_f
    end

    def __js_get__(key)
      case key
      when "identifier"
        @identifier
      when "target"
        @target
      when "clientX"
        @client_x
      when "clientY"
        @client_y
      when "pageX"
        @page_x
      when "pageY"
        @page_y
      when "screenX"
        @screen_x
      when "screenY"
        @screen_y
      when "radiusX"
        @radius_x
      when "radiusY"
        @radius_y
      when "rotationAngle"
        @rotation_angle
      when "force"
        @force
      end
    end
  end

  # `TouchList` — immutable, indexed collection of Touch points.
  class TouchList
    include Enumerable

    def initialize(touches = [])
      @touches = touches.to_a.freeze
    end

    def length
      @touches.length
    end

    def item(index)
      @touches[index.to_i]
    end

    def [](index)
      item(index)
    end

    def each(&block)
      @touches.each(&block)
      self
    end

    def __js_get__(key)
      case key
      when "length"
        length
      else
        item(key.to_i) if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
      end
    end

    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      end
    end
  end

  # `TouchEvent` — fires for touchstart / touchmove / touchend /
  # touchcancel. Carries three TouchLists plus modifier keys.
  #
  # Spec: https://w3c.github.io/touch-events/#touchevent-interface
  class TouchEvent < Event
    def initialize(type, init = nil)
      super
      @touches = TouchList.new(Array(read_init(init, "touches") || []))
      @target_touches = TouchList.new(Array(read_init(init, "targetTouches") || []))
      @changed_touches = TouchList.new(Array(read_init(init, "changedTouches") || []))
      @alt_key = !!read_init(init, "altKey")
      @ctrl_key = !!read_init(init, "ctrlKey")
      @shift_key = !!read_init(init, "shiftKey")
      @meta_key = !!read_init(init, "metaKey")
    end

    attr_reader :touches, :target_touches, :changed_touches

    def __js_get__(key)
      case key
      when "touches"
        @touches
      when "targetTouches"
        @target_touches
      when "changedTouches"
        @changed_touches
      when "altKey"
        @alt_key
      when "ctrlKey"
        @ctrl_key
      when "shiftKey"
        @shift_key
      when "metaKey"
        @meta_key
      else
        super
      end
    end
  end

  # `ClipboardEvent` — fires for copy / cut / paste. Carries the
  # `clipboardData` payload as a DataTransfer.
  #
  # Spec: https://w3c.github.io/clipboard-apis/#clipboard-event-interface
  class ClipboardEvent < Event
    def initialize(type, init = nil)
      super
      @clipboard_data = read_init(init, "clipboardData")
    end

    attr_reader :clipboard_data

    def __js_get__(key)
      case key
      when "clipboardData"
        @clipboard_data
      else
        super
      end
    end
  end

  # `CompositionEvent` — IME composition events (compositionstart /
  # compositionupdate / compositionend). `data` holds the composing text.
  class CompositionEvent < Event
    def initialize(type, init = nil)
      super
      @data = (read_init(init, "data") || "").to_s
    end

    attr_reader :data

    def __js_get__(key)
      case key
      when "data"
        @data
      else
        super
      end
    end
  end

  # `WheelEvent` — wheel-scroll events. Inherits MouseEvent (coords +
  # modifier keys) and adds delta values + a delta mode.
  class WheelEvent < MouseEvent
    DOM_DELTA_PIXEL = 0
    DOM_DELTA_LINE = 1
    DOM_DELTA_PAGE = 2

    def initialize(type, init = nil)
      super
      @delta_x = (read_init(init, "deltaX") || 0).to_f
      @delta_y = (read_init(init, "deltaY") || 0).to_f
      @delta_z = (read_init(init, "deltaZ") || 0).to_f
      @delta_mode = (read_init(init, "deltaMode") || 0).to_i
    end

    attr_reader :delta_x, :delta_y, :delta_z, :delta_mode

    def __js_get__(key)
      case key
      when "deltaX"
        @delta_x
      when "deltaY"
        @delta_y
      when "deltaZ"
        @delta_z
      when "deltaMode"
        @delta_mode
      else
        super
      end
    end
  end

  # `FocusEvent` — focus / blur / focusin / focusout. `relatedTarget`
  # is the element gaining/losing focus on the other side.
  class FocusEvent < Event
    def initialize(type, init = nil)
      super
      @related_target = read_init(init, "relatedTarget")
    end

    attr_reader :related_target

    def __js_get__(key)
      case key
      when "relatedTarget"
        @related_target
      else
        super
      end
    end
  end

  # `BeforeUnloadEvent` — `beforeunload` event. Setting `return_value`
  # to a non-empty string (or calling `preventDefault`) signals the
  # browser to prompt the user before navigating away.
  class BeforeUnloadEvent < Event
    def initialize(type = "beforeunload", init = nil)
      super
      @return_value = (read_init(init, "returnValue") || "").to_s
    end

    attr_accessor :return_value

    def __js_get__(key)
      case key
      when "returnValue"
        @return_value
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "returnValue"
        @return_value = value.to_s
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
