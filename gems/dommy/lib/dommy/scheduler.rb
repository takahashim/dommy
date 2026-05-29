# frozen_string_literal: true

module Dommy
  # Deterministic host-side scheduler for timers, rAF, and microtasks.
  # Time advances only when the host explicitly calls `advance_time`.
  class Scheduler
    Timer = Struct.new(:id, :kind, :callback, :due_at, :interval_ms, :active)

    FRAME_MS = 16

    def initialize
      @now_ms = 0
      @next_id = 1
      @timers = {}
      @microtasks = []
    end

    attr_reader :now_ms

    def set_timeout(callback, delay_ms)
      register_timer(:timeout, callback, delay_ms.to_i, nil)
    end

    def clear_timeout(id)
      cancel_timer(id)
    end

    def set_interval(callback, interval_ms)
      ms = [interval_ms.to_i, 0].max
      register_timer(:interval, callback, ms, ms)
    end

    def clear_interval(id)
      cancel_timer(id)
    end

    def request_animation_frame(callback)
      frames = ((@now_ms / FRAME_MS) + 1) * FRAME_MS
      id = next_id
      @timers[id] = Timer.new(id, :raf, callback, frames, nil, true)
      id
    end

    def cancel_animation_frame(id)
      cancel_timer(id)
    end

    def queue_microtask(callback)
      @microtasks << callback
      nil
    end

    def drain_microtasks
      until @microtasks.empty?
        callback = @microtasks.shift
        invoke_callback(callback, [@now_ms])
      end

      nil
    end

    def advance_time(delta_ms)
      target = @now_ms + [delta_ms.to_i, 0].max
      while next_due_timer_at && next_due_timer_at <= target
        @now_ms = next_due_timer_at
        run_due_timers
        drain_microtasks
      end

      @now_ms = target
      drain_microtasks
      nil
    end

    def drain_timers(advance: 0)
      advance_time(advance)
    end

    # Public accessor for eval-time auto-drain: keep advancing the
    # clock until no timers remain (or a safety budget runs out).
    def next_due_timer_at
      @timers.values.select(&:active).map(&:due_at).min
    end

    private

    def next_id
      id = @next_id
      @next_id += 1
      id
    end

    def register_timer(kind, callback, delay_ms, interval_ms)
      id = next_id
      due_at = @now_ms + [delay_ms, 0].max
      @timers[id] = Timer.new(id, kind, callback, due_at, interval_ms, true)
      id
    end

    def cancel_timer(id)
      timer = @timers[id.to_i]
      timer.active = false if timer
      @timers.delete(id.to_i)
      nil
    end

    def run_due_timers
      due = @timers.values.select { |timer| timer.active && timer.due_at <= @now_ms }
      due.sort_by!(&:id)
      due.each do |timer|
        next unless timer.active

        case timer.kind
        when :raf
          @timers.delete(timer.id)
          invoke_callback(timer.callback, [@now_ms.to_f])
        when :interval
          invoke_callback(timer.callback, [])
          timer.due_at = @now_ms + timer.interval_ms if timer.active
        else
          @timers.delete(timer.id)
          invoke_callback(timer.callback, [])
        end
      end
    end

    def invoke_callback(callback, args)
      if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", args)
      elsif callback.respond_to?(:call)
        callback.call(*args)
      end
    end
  end
end
