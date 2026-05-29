# frozen_string_literal: true

module Dommy
  # `KeyframeEffect` — wraps a target element + keyframes + timing.
  # Dommy doesn't interpolate values (no layout / render); the
  # effect is just a record of what the animation describes.
  #
  # Spec: https://drafts.csswg.org/web-animations/#keyframeeffect
  class KeyframeEffect
    attr_reader :target, :keyframes

    def initialize(target, keyframes, options = nil)
      @target = target
      @keyframes = case keyframes
      when nil
        []
      when Array
        keyframes
      else
        [keyframes]
      end

      @timing = normalize_timing(options)
    end

    def get_timing
      @timing.dup
    end

    alias getTiming get_timing

    def update_timing(timing)
      @timing.merge!(timing.transform_keys(&:to_s))
      nil
    end

    alias updateTiming update_timing

    def duration_ms
      d = @timing["duration"]
      d.is_a?(Numeric) ? d.to_i : 0
    end

    def __js_get__(key)
      case key
      when "target"
        @target
      end
    end

    def __js_call__(method, args)
      case method
      when "getTiming"
        get_timing
      when "updateTiming"
        update_timing(args[0] || {})
      end
    end

    private

    def normalize_timing(input)
      case input
      when nil
        {"duration" => 0}
      when Numeric
        {"duration" => input.to_i}
      when Hash
        h = input.transform_keys(&:to_s)
        h["duration"] = (h["duration"] || 0).is_a?(Numeric) ? h["duration"].to_i : 0
        h
      else
        {"duration" => 0}
      end
    end
  end

  # `Animation` — represents a running animation, mirroring the Web
  # Animations API's lifecycle and event surface. Dommy doesn't
  # interpolate any property values; the animation transitions
  # through "idle" → "running" → "finished" by either virtual time
  # (`scheduler.advance_time`) or by an explicit `finish()` call.
  #
  # Spec: https://drafts.csswg.org/web-animations/#animation
  class Animation
    include EventTarget

    attr_accessor :id
    attr_reader :effect, :timeline, :play_state

    def initialize(effect = nil, timeline = nil, window: nil)
      @effect = effect
      @timeline = timeline
      @window = window
      @play_state = "idle"
      @playback_rate = 1.0
      @current_time = nil
      @start_time = nil
      @id = ""
      @finished_promise = nil
      @ready_promise = nil
      @scheduled_finish_id = nil
    end

    def current_time
      @current_time
    end

    def current_time=(value)
      @current_time = value
    end

    def start_time
      @start_time
    end

    def start_time=(value)
      @start_time = value
    end

    def playback_rate
      @playback_rate
    end

    def playback_rate=(value)
      @playback_rate = value.to_f
    end

    # Start (or resume) the animation. Returns self.
    def play
      return self if @play_state == "running"

      previous = @play_state
      @play_state = "running"
      @start_time ||= @window&.scheduler&.now_ms || 0
      ensure_ready_resolved
      schedule_auto_finish if previous != "paused"
      self
    end

    def pause
      cancel_scheduled_finish
      @play_state = "paused" unless @play_state == "idle"
      self
    end

    def cancel
      cancel_scheduled_finish
      @play_state = "idle"
      @current_time = nil
      reject_finished_with_abort
      dispatch_event(Event.new("cancel"))
      self
    end

    def finish
      cancel_scheduled_finish
      @play_state = "finished"
      @current_time = effect_duration_ms
      resolve_finished
      dispatch_event(Event.new("finish"))
      self
    end

    def reverse
      @playback_rate = -@playback_rate
      play if @play_state == "idle"
      self
    end

    # PromiseValue that resolves when the animation finishes.
    # Rejected (with AbortError-style RuntimeError) on cancel.
    def finished
      @finished_promise ||= PromiseValue.new(@window)
    end

    # PromiseValue that resolves once the animation is ready to play
    # (immediately in Dommy — there's no render-thread handoff).
    def ready
      @ready_promise ||= if @window
        PromiseValue.resolve(@window, self)
      else
        PromiseValue.new(@window)
      end
    end

    def __js_get__(key)
      case key
      when "playState"
        @play_state
      when "playbackRate"
        @playback_rate
      when "currentTime"
        @current_time
      when "startTime"
        @start_time
      when "effect"
        @effect
      when "timeline"
        @timeline
      when "finished"
        finished
      when "ready"
        ready
      when "id"
        @id
      end
    end

    def __js_set__(key, value)
      case key
      when "currentTime"
        @current_time = value
      when "startTime"
        @start_time = value
      when "playbackRate"
        @playback_rate = value.to_f
      when "id"
        @id = value.to_s
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "play"
        play
      when "pause"
        pause
      when "cancel"
        cancel
      when "finish"
        finish
      when "reverse"
        reverse
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    # Event bubbling stops at Animation — it isn't part of the DOM tree.
    def __internal_event_parent__
      nil
    end

    private

    def effect_duration_ms
      @effect ? @effect.duration_ms : 0
    end

    def schedule_auto_finish
      return unless @window&.scheduler
      return if effect_duration_ms <= 0

      @scheduled_finish_id = @window.scheduler.set_timeout(
        proc { finish if @play_state == "running" },
        effect_duration_ms
      )
    end

    def cancel_scheduled_finish
      return unless @scheduled_finish_id && @window&.scheduler

      @window.scheduler.clear_timeout(@scheduled_finish_id)
      @scheduled_finish_id = nil
    end

    def ensure_ready_resolved
      ready.fulfill(self) if ready.respond_to?(:fulfill)
    end

    def resolve_finished
      finished.fulfill(self)
    end

    def reject_finished_with_abort
      return unless @finished_promise

      @finished_promise.reject(RuntimeError.new("AbortError: animation cancelled"))
    end
  end
end
