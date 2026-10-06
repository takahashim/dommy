# frozen_string_literal: true

module Dommy
  # Deterministic host-side scheduler for timers, rAF, and microtasks.
  # Time advances only when the host explicitly calls `advance_time`.
  class Scheduler
    # `id` is the handle the page sees, unique within its kind's id space
    # (timers, animation frames and idle callbacks each number their own);
    # `seq` is unique across all of them and orders same-instant tasks.
    Timer = Struct.new(:id, :kind, :callback, :due_at, :interval_ms, :active, :nesting, :args, :this, :seq)

    # HTML keeps three separate identifier spaces: setTimeout/setInterval share
    # the map of active timers, requestAnimationFrame has its own animation
    # frame callback identifier, and requestIdleCallback its own idle callback
    # identifier — so `clearTimeout(rafId)` cancels nothing.
    # The rendering-update steps (render_before / render) are internal, so
    # their handles are a space of their own that no page call can name.
    ID_SPACES = {timeout: :timer, interval: :timer, raf: :raf, idle: :idle, render_before: :render, render: :render}.freeze

    FRAME_MS = 16

    # HTML timer initialization steps: once a timer is nested deeper than 5, a
    # sub-4ms timeout is clamped to 4ms. Besides matching browsers, this is what
    # stops a self-rescheduling setTimeout(0) / setInterval(0) from spinning
    # forever at the same virtual instant (the clamp pushes it into a future
    # frame, so `advance_time(0)`'s due-now loop terminates).
    MAX_NESTING_BEFORE_CLAMP = 5
    MIN_NESTED_DELAY_MS = 4

    # requestIdleCallback has no real idle period here; the callback always
    # sees a fixed budget and didTimeout: false.
    IDLE_TIME_REMAINING_MS = 50.0

    # The IdleDeadline a requestIdleCallback callback is handed:
    # `timeRemaining()` (a method, as the IDL has it) and `didTimeout`.
    class IdleDeadline
      include Bridge::Methods
      js_methods %w[timeRemaining]

      def initialize(time_remaining, did_timeout)
        @time_remaining = time_remaining
        @did_timeout = did_timeout
      end

      def time_remaining = @time_remaining
      def did_timeout = @did_timeout

      def __js_get__(key)
        key == "didTimeout" ? @did_timeout : nil
      end

      def __js_call__(method, _args)
        case method
        when "timeRemaining" then @time_remaining
        end
      end
    end

    def initialize
      @now_ms = 0
      @next_seq = 1
      @next_ids = Hash.new(1)
      @timers = {}
      @handles = Hash.new { |h, k| h[k] = {} }
      @microtasks = []
      @native_microtask_scheduler = nil
      @external_inbox = Thread::Queue.new
      # The nesting level of the timer task currently running (0 at top level);
      # a timer scheduled while it runs nests one deeper. Drives the 4ms clamp.
      @nesting_level = 0
      # Opt-in: run a microtask checkpoint after EACH animation-frame callback
      # rather than once after the whole frame's batch. Off by default (WHATWG
      # batches the frame's rAF callbacks under a single checkpoint). A test
      # harness that drives async frameworks enables it so a framework whose
      # rAF-scheduled promise chain (Turbo's stream render -> self-removal) must
      # settle before another same-frame rAF callback (the test's own
      # `await nextAnimationFrame()` assertion) observes the result — matching the
      # ordering a real browser's inter-frame timing produces in practice.
      @raf_checkpoint_each = false
    end

    attr_reader :now_ms

    # Post a completion to be run on the page (JS) thread the next time the event
    # loop drains. THREAD-SAFE: this is the one place another thread may hand work
    # back — e.g. a network worker delivering a response. It only enqueues a
    # thunk; the thunk runs single-threaded with the DOM/JS (see #deliver_external),
    # so workers never touch Dommy/QuickJS state. The thunk takes no arguments.
    def post_external(&thunk)
      @external_inbox << thunk
      nil
    end

    # Run all externally-posted completions. PAGE THREAD ONLY — drained as part of
    # advancing the event loop (see #advance_time).
    def deliver_external
      until @external_inbox.empty?
        thunk = @external_inbox.pop(true)
        CallableInvoker.invoke(thunk)
      end
      nil
    rescue ThreadError
      nil # raced empty between empty? and pop — nothing left to do
    end

    # True when a worker has handed back work not yet delivered. Lets the host
    # keep the loop alive (ticking) until in-flight network responses are applied.
    def external_pending? = !@external_inbox.empty?

    # An optional hook (set by a JS runtime) that enqueues a microtask onto the
    # engine's NATIVE promise-job queue. When present, `queue_microtask` routes
    # through it so host-side microtasks (e.g. MutationObserver delivery)
    # interleave FIFO with JS `await`/Promise reactions instead of draining on a
    # separate pass. Absent in vanilla CRuby use (falls back to `@microtasks`).
    attr_accessor :native_microtask_scheduler

    # An optional hook (set by a JS runtime) invoked when a timer / rAF / idle
    # callback raises. The host inspects the error and returns truthy to swallow
    # it — e.g. a runtime execution-budget interrupt: a runaway callback the
    # engine force-killed should be recorded and let browsing continue, not crash
    # it (WHATWG: a timer callback's exception must not escape its dispatch). When
    # swallowed, the offending timer is dropped so a self-rescheduling interval
    # does not re-fire and re-stall every tick. Returning falsy (or no handler at
    # all — vanilla CRuby use) re-raises, so genuine host bugs still surface.
    attr_accessor :timer_error_handler

    # WHATWG "report an exception" for a task, supplied by the Window that owns
    # this scheduler. A timer / rAF callback that throws is the page's bug, not
    # the host's: the exception is reported at the global (firing
    # `window.onerror`) and the event loop carries on with the remaining tasks,
    # rather than tearing down whatever Ruby drove the clock. Absent in vanilla
    # CRuby use, where a throwing callback keeps propagating.
    attr_accessor :exception_reporter

    # An optional hook (set by a JS runtime) that drains the ENGINE's microtask
    # (promise-job) queue — the other half of a microtask checkpoint. The
    # scheduler owns only its own `@microtasks`; the real microtask queue lives
    # in the JS engine, so a spec-compliant checkpoint must drain both. WHATWG
    # §8.1.7.3: the event loop performs a microtask checkpoint after running each
    # task. Without this the scheduler would run every due timer task back-to-back
    # and only drain microtasks once at the end, which reorders a microtask queued
    # by one task after the next task — breaking code (Apollo/RxJS link chains)
    # that relies on the per-task checkpoint. Absent in vanilla CRuby use (then a
    # checkpoint drains only `@microtasks`).
    attr_accessor :microtask_checkpoint

    # See @raf_checkpoint_each: opt-in per-callback microtask checkpointing for
    # animation frames (test harnesses driving async frameworks).
    attr_accessor :raf_checkpoint_each

    # `args` are the arguments the callback is invoked with and `this` its
    # callback this value (the window, for the page's own timers).
    def set_timeout(callback, delay_ms, args = [], this: nil)
      register_timer(:timeout, callback, delay_ms.to_i, nil, args, this)
    end

    def clear_timeout(id)
      cancel_timer(:timer, id)
    end

    def set_interval(callback, interval_ms, args = [], this: nil)
      ms = [interval_ms.to_i, 0].max
      register_timer(:interval, callback, ms, ms, args, this)
    end

    def clear_interval(id)
      cancel_timer(:timer, id)
    end

    def request_animation_frame(callback)
      frames = ((@now_ms / FRAME_MS) + 1) * FRAME_MS
      # rAF is frame-aligned (never the same instant twice), so it needs no
      # nesting clamp; nesting 0.
      add_timer(Timer.new(nil, :raf, callback, frames, nil, true, 0, [], nil))
    end

    def cancel_animation_frame(id)
      cancel_timer(:raf, id)
    end

    # The parts of HTML's "update the rendering" that are not animation
    # frame callbacks, at the next frame boundary: `phase` :before runs ahead
    # of that frame's rAF callbacks (flushing autofocus candidates), :after
    # behind them (the focus fixup). A document asks for one only when it
    # has such work, so an idle page schedules nothing.
    def request_rendering_update(callback, phase: :after)
      frames = ((@now_ms / FRAME_MS) + 1) * FRAME_MS
      add_timer(Timer.new(nil, phase == :before ? :render_before : :render, callback, frames, nil, true, 0, [], nil))
    end

    # WHATWG requestIdleCallback — modeled as a deferred timer that hands the
    # callback an IdleDeadline. No real idle period in dommy.
    def request_idle_callback(callback, timeout = 0)
      register_timer(:idle, callback, timeout.to_i, nil, [], nil)
    end

    def cancel_idle_callback(id)
      cancel_timer(:idle, id)
    end

    def queue_microtask(callback)
      if @native_microtask_scheduler
        @native_microtask_scheduler.call(callback)
      else
        @microtasks << callback
      end
      nil
    end

    def drain_microtasks
      until @microtasks.empty?
        callback = @microtasks.shift
        CallableInvoker.invoke(callback, @now_ms)
      end

      nil
    end

    # A WHATWG microtask checkpoint: drain the scheduler's own microtask queue
    # AND the engine's promise-job queue (via the runtime hook). Host-side
    # microtasks route onto the engine queue when a runtime is wired, so in that
    # mode `@microtasks` is usually empty and the engine drain does the work; in
    # vanilla CRuby the engine hook is absent and only `@microtasks` drains.
    def perform_microtask_checkpoint
      drain_microtasks
      @microtask_checkpoint&.call
      nil
    end

    def advance_time(delta_ms)
      deliver_external # apply any responses that arrived since the last drain
      target = @now_ms + [delta_ms.to_i, 0].max
      while next_due_timer_at && next_due_timer_at <= target
        @now_ms = next_due_timer_at
        run_due_timers
        perform_microtask_checkpoint
        deliver_external
      end

      @now_ms = target
      perform_microtask_checkpoint
      deliver_external
      nil
    end

    def drain_timers(advance: 0)
      advance_time(advance)
    end

    # Run the tasks due at the current instant, one at a time and in the order
    # they were queued (each followed by a microtask checkpoint), until the
    # block answers true or no task is due — without advancing the clock and
    # without running a rendering update. Script boot uses it to run the tasks
    # queued ahead of a document's `load` event (its own, and whatever the page
    # queued before it), so a host that boots a page sees it loaded. Returns
    # the block's last answer.
    def run_tasks_until
      deliver_external
      loop do
        return true if yield

        timer = @timers.values
          .select { |t| t.active && t.due_at <= @now_ms && TASK_KINDS.include?(t.kind) }
          .min_by(&:seq)
        return false unless timer

        run_task_timer(timer)
        deliver_external
      end
    end

    TASK_KINDS = %i[timeout interval idle].freeze

    # Public accessor for eval-time auto-drain: keep advancing the
    # clock until no timers remain (or a safety budget runs out).
    def next_due_timer_at
      @timers.values.select(&:active).map(&:due_at).min
    end

    # The earliest due time among pending requestAnimationFrame callbacks, or
    # nil when none are scheduled. Lets a host flush RAF (advancing to the next
    # frame boundary) during a `settle` without jumping the clock past
    # not-yet-due `setTimeout`s.
    def next_animation_frame_at
      @timers.values.select { |t| t.active && t.kind == :raf }.map(&:due_at).min
    end

    private

    def register_timer(kind, callback, delay_ms, interval_ms, args, this)
      nesting = @nesting_level + 1
      delay = clamp_nested_delay([delay_ms, 0].max, nesting)
      due_at = @now_ms + delay
      add_timer(Timer.new(nil, kind, callback, due_at, interval_ms, true, nesting, Array(args), this))
    end

    # File the timer under a fresh handle in its kind's id space; returns the
    # handle.
    def add_timer(timer)
      space = ID_SPACES.fetch(timer.kind)
      timer.id = @next_ids[space]
      @next_ids[space] += 1
      timer.seq = @next_seq
      @next_seq += 1
      @timers[timer.seq] = timer
      @handles[space][timer.id] = timer
      timer.id
    end

    def remove_timer(timer)
      @timers.delete(timer.seq)
      @handles[ID_SPACES.fetch(timer.kind)].delete(timer.id)
    end

    # HTML timer initialization step: a timer nested deeper than 5 with a sub-4ms
    # timeout is clamped to 4ms.
    def clamp_nested_delay(delay, nesting)
      nesting > MAX_NESTING_BEFORE_CLAMP && delay < MIN_NESTED_DELAY_MS ? MIN_NESTED_DELAY_MS : delay
    end

    def cancel_timer(space, id)
      # WHATWG: clearTimeout/clearInterval with a missing or non-numeric handle
      # (e.g. `clearTimeout(undefined)`, which React's scheduler emits) is a
      # silent no-op rather than an error.
      return unless id.respond_to?(:to_i)

      timer = @handles[space][id.to_i]
      return unless timer

      timer.active = false
      remove_timer(timer)
      nil
    end

    def run_due_timers
      due = @timers.values.select { |timer| timer.active && timer.due_at <= @now_ms }
      # A frame's rendering-update steps come before or after its rAF
      # callbacks.
      phase_order = { render_before: 0, render: 2 }
      due.sort_by! { |timer| [phase_order.fetch(timer.kind, 1), timer.seq] }
      # Each ordinary timer task is followed by a microtask checkpoint (WHATWG
      # §8.1.7.3). The animation-frame callbacks of one rendering update are an
      # exception: they run consecutively and share a single checkpoint after the
      # batch (a microtask queued by one rAF must not run before the next rAF in
      # the same frame), so they are checkpointed once at the end.
      raf_ran = false
      due.each do |timer|
        next unless timer.active

        case timer.kind
        when :raf
          remove_timer(timer)
          invoke_timer(timer, @now_ms.to_f)
          raf_ran = true
          # Opt-in (test harness): settle this callback's microtask chain before
          # the next same-frame rAF callback runs (see @raf_checkpoint_each).
          perform_microtask_checkpoint if @raf_checkpoint_each
        when :interval, :idle
          run_task_timer(timer)
        when :render_before
          remove_timer(timer)
          invoke_timer(timer)
          perform_microtask_checkpoint
        when :render
          # The rAF batch's shared checkpoint comes first.
          perform_microtask_checkpoint if raf_ran
          raf_ran = false
          remove_timer(timer)
          invoke_timer(timer)
          perform_microtask_checkpoint
        else
          run_task_timer(timer)
        end
      end
      perform_microtask_checkpoint if raf_ran
    end

    # Run one timer task (a timeout, an interval iteration, an idle callback),
    # then a microtask checkpoint.
    def run_task_timer(timer)
      case timer.kind
      when :interval
        invoke_timer(timer, *timer.args)
        if timer.active
          # Each interval iteration nests one deeper, so a setInterval(0) is
          # clamped to 4ms once past the nesting threshold (HTML timer steps).
          timer.nesting += 1
          timer.due_at = @now_ms + clamp_nested_delay(timer.interval_ms, timer.nesting)
        end
      when :idle
        remove_timer(timer)
        invoke_timer(timer, IdleDeadline.new(IDLE_TIME_REMAINING_MS, false))
      else
        remove_timer(timer)
        invoke_timer(timer, *timer.args)
      end
      perform_microtask_checkpoint
    end


    # Run a single timer's callback. The callback is invoked in its RAISING form
    # so a JS throw surfaces here instead of being swallowed by the bridge —
    # WHATWG reports a task's exception at the global and keeps the event loop
    # running, which a silently dropped throw cannot do. The raised error is then
    # offered to `timer_error_handler` (set by the JS runtime); if it swallows the
    # error the timer is dropped (so a runaway interval cannot re-stall every
    # tick) and browsing continues. With no handler — or one that declines — the
    # error propagates, preserving the default crash-on-bug behavior for a host
    # bug, which is not a page exception and must not be reported as one.
    def invoke_timer(timer, *args)
      # Run the callback at this timer's nesting level, so a timer it schedules
      # nests one deeper (driving the 4ms clamp). Restored even if it throws.
      prev_nesting = @nesting_level
      @nesting_level = timer.nesting || 0
      CallableInvoker.invoke_raising(timer.callback, *args, this: timer.this)
    rescue StandardError => e
      # A page exception is reported and the timer keeps its schedule, like a
      # browser: an interval whose callback throws goes on firing.
      return nil if report_task_exception(e)
      # Otherwise the runtime's handler decides. It swallows the errors it had to
      # kill (an execution-timeout runaway, a poisoned VM), and those DO drop the
      # timer so it cannot re-stall every tick. A declined error is a host bug.
      raise unless @timer_error_handler&.call(e, timer)

      timer.active = false
      remove_timer(timer)
      nil
    ensure
      @nesting_level = prev_nesting
    end

    # Report a task's exception at the global, per WHATWG. Only a `ThrowValue`
    # qualifies: it is the one shape that unambiguously came out of page JS, so a
    # host-side bug (a NoMethodError in Dommy itself) is never disguised as a
    # page error — it falls through and propagates.
    def report_task_exception(error)
      return false unless error.is_a?(Bridge::ThrowValue) && @exception_reporter

      @exception_reporter.call(error)
      true
    end
  end
end
