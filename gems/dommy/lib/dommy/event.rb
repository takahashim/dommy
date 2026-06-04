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
      entry = Listener.new(cb, options)
      # Per spec, a listener is deduplicated by (type, callback, capture) — so
      # the same function may be registered once as a capture and once as a
      # bubble listener.
      return nil if list.any? { |e| e.listener.equal?(cb) && e.capture? == entry.capture? }

      list << entry

      # `{ signal: AbortSignal }` — when the signal aborts, auto-
      # remove the listener. Per spec, if the signal is already aborted
      # the listener must not be registered at all.
      signal = options.is_a?(Hash) ? (options["signal"] || options[:signal]) : nil
      if signal.respond_to?(:__js_get__)
        if signal.__js_get__("aborted")
          remove_event_listener(type, cb, options)
        else
          target = self
          signal.__js_call__(
            "addEventListener",
            [
              "abort",
              proc {
                target.remove_event_listener(type, cb, options)
              }
            ]
          )
        end
      end

      nil
    end

    def remove_event_listener(type, listener, options = nil)
      return nil if type.nil? || listener.nil?

      # Per spec, a listener is identified by (type, callback, capture) — so
      # removing must match the capture flag, not just the callback (a function
      # registered as both a capture and a bubble listener is two listeners).
      capture = EventTarget.capture_flag(options)
      listeners_for(type.to_s).reject! do |entry|
        entry.listener.equal?(listener) && entry.capture? == capture
      end
      nil
    end

    def dispatch_event(event)
      return true if event.nil?

      # Per spec, dispatchEvent must receive an Event instance.
      raise TypeError, "dispatchEvent requires an Event, got #{event.class}" unless event.is_a?(Event)

      event.__internal_prepare_for_dispatch__(self)
      event.__internal_set_dispatch_flag__(true)

      # The full propagation path: the target plus its ancestors (root last).
      # Capturing always traverses the ancestors regardless of `bubbles`.
      path = event.__js_get__("composed") ? composed_bubble_path(event) : event_bubble_path
      event.__internal_record_path__(path) if event.respond_to?(:__internal_record_path__)
      ancestors = path[1..] || []

      catch(:stop_propagation) do
        # Capturing phase: root → … → parent, capture listeners only.
        event.__internal_set_event_phase__(Event::CAPTURING_PHASE)
        ancestors.reverse_each do |node|
          deliver_at(node, event, :capture)
        end

        # At the target: both capture and bubble listeners.
        event.__internal_set_event_phase__(Event::AT_TARGET)
        deliver_at(self, event, :both)

        # Bubbling phase: parent → … → root, bubble listeners only (only when
        # the event bubbles).
        if event.bubbles?
          event.__internal_set_event_phase__(Event::BUBBLING_PHASE)
          ancestors.each do |node|
            deliver_at(node, event, :bubble)
          end
        end
      end

      # After dispatch, currentTarget reverts to null and eventPhase to NONE, and
      # the propagation flags are unset so the event can be dispatched again.
      event.__internal_set_current_target__(nil)
      event.__internal_set_event_phase__(Event::NONE)
      event.__internal_clear_propagation_flags__
      event.__internal_set_dispatch_flag__(false)

      !event.default_prevented?
    end

    # Deliver `event` to one node's listeners for the current phase, then honor
    # stopPropagation (throws to end the whole walk after this node finishes).
    def deliver_at(node, event, phase)
      # Honor a stop-propagation flag set before reaching this node (including
      # one set before dispatch began) — the spec checks it before invoking a
      # node's listeners, not only after.
      throw :stop_propagation if event.propagation_stopped?

      event.__internal_set_current_target__(node)
      node.__internal_deliver_event__(event, phase)
      throw :stop_propagation if event.propagation_stopped?
    end

    # `phase` is :capture (capture listeners), :bubble (non-capture), or :both
    # (at the target). stopImmediatePropagation ends delivery within this node.
    def __internal_deliver_event__(event, phase = :both)
      listeners = listeners_for(event.type).dup
      listeners.each do |entry|
        next unless phase == :both || (phase == :capture ? entry.capture? : !entry.capture?)

        # Spec: a `once` listener is removed BEFORE its callback runs, so a nested
        # dispatch from within the callback can't invoke it a second time.
        if entry.once?
          listeners_for(event.type).reject! do |candidate|
            candidate.listener.equal?(entry.listener) && candidate.capture? == entry.capture?
          end
        end

        if entry.passive?
          event.__internal_run_passive__ { CallableInvoker.invoke_listener(entry.listener, event) }
        else
          CallableInvoker.invoke_listener(entry.listener, event)
        end

        break if event.immediate_propagation_stopped?
      end

      nil
    end

    # The next target up the propagation path. The default (no parent) suits
    # EventTargets that aren't tree nodes (AbortSignal, XHR, …); Element /
    # Document / ShadowRoot override it to walk the node tree.
    def __internal_event_parent__
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

      # useCapture: a boolean third argument, or `{capture: …}` in the options
      # dictionary. A capture listener fires in the capturing phase; a non-capture
      # listener in the bubbling phase (both at the target).
      def capture?
        EventTarget.capture_flag(options)
      end

      # `{ passive: true }` — the listener promises not to call preventDefault,
      # so the event's preventDefault() is neutralized while it runs.
      def passive?
        case options
        when Hash
          EventTarget.js_truthy?(options.key?("passive") ? options["passive"] : options[:passive])
        else
          false
        end
      end
    end

    # The capture flag for an addEventListener/removeEventListener options
    # argument, using JS — not Ruby — truthiness: a boolean useCapture, or the
    # `capture` member of an options dictionary, where 0 / "" / NaN / null /
    # undefined are falsy (in Ruby 0 and "" are truthy, so a naive `!!` is wrong).
    def self.capture_flag(options)
      raw =
        if options.is_a?(Hash)
          options.key?("capture") ? options["capture"] : options[:capture]
        else
          options
        end
      js_truthy?(raw)
    end

    # JS ToBoolean: false for false/null/undefined, +0/-0, NaN, and "".
    def self.js_truthy?(value)
      return false if value.nil? || value == false
      return false if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)
      return false if value.is_a?(Numeric) && (value.zero? || (value.respond_to?(:nan?) && value.nan?))
      # The bridge marshals JS NaN as the symbol :NaN (it has no Ruby Float
      # equivalent that survives the round-trip), which ToBoolean treats as false.
      return false if value == :NaN
      return false if value == ""

      true
    end

    def listeners_for(type)
      @event_listeners ||= Hash.new { |h, k| h[k] = [] }
      @event_listeners[type]
    end

    def event_bubble_path
      path = [self]
      current = self
      while (current = current.__send__(:__internal_event_parent__))
        path << current
      end

      path
    end

    # Build the propagation path with optional shadow-boundary
    # crossing. When the in-flight event has `composed: true`, the
    # walk continues from a ShadowRoot to its host; otherwise it
    # stops at the shadow boundary (nil from `__internal_event_parent__`).
    def composed_bubble_path(event)
      path = [self]
      current = self
      loop do
        nxt = current.__send__(:__internal_event_parent__)
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
      return nil unless target.respond_to?(:__dommy_backend_node__)

      doc = target.instance_variable_get(:@document)
      return nil unless doc && doc.respond_to?(:__internal_shadow_root_containing__)

      doc.__internal_shadow_root_containing__(target.__dommy_backend_node__)
    end

  end

  class StandaloneEventTarget
    include EventTarget

    include Bridge::Methods
    js_methods %w[addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      else
        nil
      end
    end

    def __internal_event_parent__
      nil
    end
  end

  class Event
    NONE = 0
    CAPTURING_PHASE = 1
    AT_TARGET = 2
    BUBBLING_PHASE = 3

    def initialize(type, init = nil)
      @type = type.to_s
      @bubbles = !!read_init(init, "bubbles")
      @cancelable = !!read_init(init, "cancelable")
      @composed = !!read_init(init, "composed")
      @default_prevented = false
      @propagation_stopped = false
      @immediate_propagation_stopped = false
      # Set while a passive listener runs, so preventDefault() is a no-op (per
      # the passive listener flag in the DOM spec).
      @in_passive_listener = false
      @target = nil
      @current_target = nil
      @event_phase = NONE
      @composed_path = []
      # `timeStamp` is the high-resolution timestamp at construction
      # in ms (browser uses performance.now). We use monotonic time
      # for determinism across spec runs.
      @time_stamp = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0)
      @trusted = false
    end

    # Mark this event as UA-generated (`isTrusted === true`). Used by the host
    # for events it fires itself (e.g. AbortSignal's "abort").
    def __internal_mark_trusted__
      @trusted = true
      self
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

    # Run a block with the passive-listener flag set, so any preventDefault()
    # inside it is neutralized. Restores the prior flag afterward.
    def __internal_run_passive__
      previous = @in_passive_listener
      @in_passive_listener = true
      yield
    ensure
      @in_passive_listener = previous
    end

    def __internal_prepare_for_dispatch__(target)
      @target ||= target
    end

    # End-of-dispatch cleanup: the dispatch algorithm unsets the stop-propagation
    # and stop-immediate-propagation flags (but NOT the canceled flag), so the
    # same event object can be dispatched again. A stopPropagation() issued
    # before the next dispatch is still honored — only the post-dispatch state is
    # cleared here.
    def __internal_clear_propagation_flags__
      @propagation_stopped = false
      @immediate_propagation_stopped = false
      nil
    end

    def __internal_set_current_target__(target)
      @current_target = target
    end

    def __internal_set_event_phase__(phase)
      @event_phase = phase
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
      when "returnValue"
        # Legacy alias: false once the default has been prevented, else true.
        !@default_prevented
      when "isTrusted"
        # Script-created events are untrusted; a UA-fired event (e.g. an
        # AbortSignal's "abort") is marked trusted via __internal_mark_trusted__.
        @trusted == true
      when "target", "srcElement"
        # srcElement is a legacy alias of target — null (not undefined) when unset.
        @target
      when "currentTarget"
        @current_target
      when "timeStamp"
        @time_stamp
      when "cancelBubble"
        @propagation_stopped
      when "eventPhase"
        event_phase
      else
        # An unknown property reads back as JS `undefined`, not `null` — e.g. a
        # non-dictionary member passed to the constructor (`new Event("x", {sweet:
        # 1}).sweet`) is not reflected on the event. Genuinely-null DOM attributes
        # (target/currentTarget/…) are explicit cases above and still return nil.
        Bridge::UNDEFINED
      end
    end

    def __js_set__(key, value)
      case key
      when "cancelBubble"
        # Setting to truthy stops propagation; spec quirk that
        # `cancelBubble = false` does NOT un-stop (browser observation).
        @propagation_stopped = true if value
      when "returnValue"
        # Legacy alias: returnValue = false cancels the event (like
        # preventDefault); a truthy value does not un-cancel.
        @default_prevented = true if !value && @cancelable
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[preventDefault stopPropagation stopImmediatePropagation composedPath initEvent]
    def __js_call__(method, args)
      case method
      when "preventDefault"
        # A passive listener's preventDefault() is a no-op (DOM "passive listener
        # flag"), so the default action proceeds — what Stimulus's :passive
        # action option relies on.
        @default_prevented = true if @cancelable && !@in_passive_listener
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
        # WebIDL: the `type` argument is mandatory.
        raise Bridge::TypeError, "initEvent requires a type argument" if args.empty?

        init_event(args[0], args[1], args[2])
      end
    end

    # Set while the event is being dispatched, so initEvent() can short-circuit.
    def __internal_set_dispatch_flag__(flag)
      @dispatch_flag = flag
      nil
    end

    # Deprecated `Event#initEvent(type, bubbles, cancelable)` — older
    # browsers used `document.createEvent("Event").initEvent(...)`.
    # Resets internal flags as a side effect.
    def init_event(type, bubbles = false, cancelable = false)
      # Spec: initEvent is a no-op while the event is being dispatched.
      return nil if @dispatch_flag

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
    def __internal_record_path__(targets)
      @composed_path = if @type == "load"
        targets.reject { |t| t.is_a?(Window) }
      else
        targets
      end
    end

    private

    def event_phase
      @event_phase
    end

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
    attr_reader :detail

    def initialize(type, init = nil)
      super
      @detail = read_init(init, "detail")
    end

    def __js_get__(key)
      return @detail if key == "detail"

      super
    end

    js_methods %w[initCustomEvent]
    def __js_call__(method, args)
      case method
      when "initCustomEvent"
        # Deprecated initCustomEvent(type, bubbles=false, cancelable=false,
        # detail=null). Like initEvent, the type is mandatory and the whole call
        # is a no-op while the event is being dispatched.
        raise Bridge::TypeError, "initCustomEvent requires a type argument" if args.empty?

        unless @dispatch_flag
          init_event(args[0], args[1], args[2])
          @detail = args[3]
        end
        nil
      else
        super
      end
    end
  end

  # PopStateEvent — fired on history back/forward. Exposes the history entry's
  # serialized state via `event.state` (the spec property; framework routers like
  # Turbo read `event.state.turbo` to recognise their own navigations and restore
  # the cached page). A plain `Event` subclass per spec — NOT a CustomEvent, so it
  # has no `detail` and `instanceof CustomEvent` is false.
  class PopStateEvent < Event
    attr_reader :state

    def initialize(type, init = nil)
      super
      @state = read_init(init, "state")
    end

    def __js_get__(key)
      return @state if key == "state"

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

    include Bridge::Methods
    js_methods %w[item]
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
    def self.abort(*reason)
      signal = new
      signal.__internal_mark_aborted__(*reason)
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
        scheduler.set_timeout(proc { signal.__internal_mark_aborted__(reason) }, ms.to_i)
      else
        signal.__internal_schedule_thread_timeout__(ms.to_i, reason)
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
        composite.__internal_mark_aborted__(already.reason)
        return composite
      end

      composite.__internal_make_dependent__
      list.each do |sig|
        # A plain source signal links directly; a composite is flattened to its
        # own (already-flat) source signals, so the dependency graph stays one
        # level deep and abort order is well-defined.
        sources = sig.__internal_dependent__? ? sig.__internal_source_signals__ : [sig]
        sources.each do |source|
          next if composite.__internal_source_signals__.include?(source)

          composite.__internal_add_source__(source)
          source.__internal_add_dependent__(composite)
        end
      end

      composite
    end

    def initialize
      @aborted = false
      @reason = nil
      # The WHATWG "dependent signal" model backing AbortSignal.any: a composite
      # signal flattens to its original (non-dependent) source signals, and each
      # source holds an ordered list of the composites depending on it — so abort
      # propagation fires in source-then-dependents order, not via event chaining.
      @dependent = false
      @source_signals = []
      @dependent_signals = []
      # WHATWG "abort algorithms": callbacks run synchronously during abort,
      # BEFORE the "abort" event — so a consumer (e.g. an Observable subscription)
      # can tear down ahead of any externally-registered abort listener.
      @abort_algorithms = []
    end

    # Background-thread timeout used by `AbortSignal.timeout` when no
    # scheduler is provided. Kept package-private; tests can also
    # drive the abort manually via `__internal_mark_aborted__`.
    def __internal_schedule_thread_timeout__(ms, reason)
      Thread.new do
        sleep(ms.to_f / 1000.0)
        __internal_mark_aborted__(reason)
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
      # An Exception reason (the default AbortError, or an explicit DOMException)
      # is raised so the bridge tags it as a real JS error; any other reason — a
      # string, number, or opaque JSValue — is thrown verbatim, identity kept.
      raise @reason if @reason.is_a?(Exception)

      raise Bridge::ThrowValue.new(@reason)
    end

    alias throwIfAborted throw_if_aborted

    def __js_get__(key)
      case key
      when "aborted"
        @aborted
      when "reason"
        # A non-aborted signal's reason is `undefined` (not null); once aborted
        # it is the abort reason (an explicit value or the default AbortError).
        @aborted ? @reason : Bridge::UNDEFINED
      when "onabort"
        @onabort_handler
      end
    end

    # `signal.onabort = fn` is an event-handler IDL attribute: it registers a
    # single "abort" listener (replacing any previous one); null/undefined clears
    # it. (Setting it after the signal is already aborted never fires.)
    def __js_set__(key, value)
      return Bridge::UNHANDLED unless key == "onabort"

      remove_event_listener("abort", @onabort_handler) if @onabort_handler
      cleared = value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
      @onabort_handler = cleared ? nil : value
      add_event_listener("abort", @onabort_handler) if @onabort_handler
      nil
    end

    include Bridge::Methods
    js_methods %w[addEventListener removeEventListener dispatchEvent throwIfAborted __internalAddAbortAlgorithm]
    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "throwIfAborted"
        throw_if_aborted
      when "__internalAddAbortAlgorithm"
        __internal_add_abort_algorithm__(args[0])
      end
    end

    # Register an abort algorithm (WHATWG "add an algorithm to a signal"): it runs
    # synchronously when the signal aborts, before the "abort" event. A no-op once
    # already aborted — the caller handles that case itself. Exposed to the JS
    # Observable polyfill so a subscription's consumer-abort fires ahead of any
    # external abort listener (the spec's downstream-before-upstream ordering).
    def __internal_add_abort_algorithm__(callback)
      @abort_algorithms << callback unless @aborted
      nil
    end

    # Sentinel meaning "no reason argument was supplied" — distinct from an
    # explicit `null` reason (`abort(null)` keeps reason null, but `abort()` /
    # `abort(undefined)` default to a fresh AbortError).
    NO_REASON = Object.new

    # WHATWG "signal abort": set the reason, then propagate to dependent signals
    # — firing "abort" at this signal FIRST and then at each dependent in the
    # order it was registered (the reasons are all stamped before any event
    # fires, so a handler observing a sibling sees it already aborted).
    def __internal_mark_aborted__(reason = NO_REASON)
      return if @aborted

      @aborted = true
      no_reason = reason.equal?(NO_REASON) || (defined?(Bridge::UNDEFINED) && reason.equal?(Bridge::UNDEFINED))
      @reason = no_reason ? DOMException::AbortError.new("signal is aborted without reason") : reason

      dependents_to_abort = []
      @dependent_signals.each do |dependent|
        next if dependent.aborted?

        dependent.__internal_set_reason__(@reason)
        dependents_to_abort << dependent
      end

      __internal_run_abort_steps__
      dependents_to_abort.each(&:__internal_run_abort_steps__)
    end

    # ----- dependent-signal plumbing (package-private, used by .any) -----

    def __internal_make_dependent__
      @dependent = true
    end

    def __internal_dependent__?
      @dependent
    end

    def __internal_source_signals__
      @source_signals
    end

    def __internal_add_source__(source)
      @source_signals << source
    end

    def __internal_add_dependent__(dependent)
      @dependent_signals << dependent
    end

    # Mark aborted with a reason WITHOUT firing — the orchestrating source stamps
    # every dependent's reason up front, then fires the events in order.
    def __internal_set_reason__(reason)
      @aborted = true
      @reason = reason
    end

    # The spec's "abort steps": run the registered abort algorithms first
    # (synchronously, ahead of any listener), then fire the trusted "abort" event.
    def __internal_run_abort_steps__
      algorithms = @abort_algorithms
      @abort_algorithms = []
      algorithms.each { |algo| invoke_abort_algorithm(algo) }
      dispatch_event(Event.new("abort", "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
    end

    # Run one abort algorithm (a JS callback over the bridge, or a Ruby proc).
    # A throw is swallowed deliberately: WHATWG runs every abort algorithm and
    # then fires the "abort" event regardless, so one algorithm's failure must
    # not abort the run. (The sole caller — the Observable polyfill — already
    # catches inside its own teardown, so this is a defensive backstop.)
    def invoke_abort_algorithm(algo)
      if algo.respond_to?(:__js_call__)
        algo.__js_call__("call", [])
      elsif algo.respond_to?(:call)
        algo.call
      end
    rescue StandardError
      nil
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
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[abort]
    def __js_call__(method, args)
      case method
      when "abort"
        # `abort()` (no arg) defaults the reason; `abort(reason)` — even
        # `abort(null)` — keeps the explicit reason.
        args.empty? ? @signal.__internal_mark_aborted__ : @signal.__internal_mark_aborted__(args[0])
      end
    end
  end
end
