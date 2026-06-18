# frozen_string_literal: true

require_relative "test_helper"

class TestScheduler < Minitest::Test
  def setup
    @sched = Dommy::Scheduler.new
  end

  def test_set_timeout_runs_after_advance
    fired = []
    @sched.set_timeout(proc { fired << :hi }, 50)
    @sched.advance_time(49)
    assert_empty(fired)
    @sched.advance_time(1)
    assert_equal([:hi], fired)
  end

  def test_clear_timeout_cancels
    fired = []
    id = @sched.set_timeout(proc { fired << :x }, 10)
    @sched.clear_timeout(id)
    @sched.advance_time(100)
    assert_empty(fired)
  end

  def test_set_interval_fires_repeatedly
    counts = [0]
    @sched.set_interval(proc { counts[0] += 1 }, 10)
    @sched.advance_time(35)
    assert_equal(3, counts[0])
  end

  def test_request_animation_frame_aligned_to_frame_ms
    times = []
    @sched.request_animation_frame(proc { |t| times << t })
    @sched.advance_time(20)
    assert_equal(1, times.size)
    assert_equal(Dommy::Scheduler::FRAME_MS.to_f, times.first)
  end

  def test_microtask_runs_via_drain
    fired = []
    @sched.queue_microtask(proc { fired << :m })
    assert_empty(fired)
    @sched.drain_microtasks
    assert_equal([:m], fired)
  end

  # An externally-posted completion (e.g. a network worker delivering a response)
  # runs on the next event-loop advance — the cross-thread handoff for async I/O.
  def test_external_completion_runs_on_advance
    fired = []
    @sched.post_external { fired << :done }
    assert @sched.external_pending?
    assert_empty(fired, "not run until the loop drains it")
    @sched.advance_time(0)
    assert_equal([:done], fired)
    refute @sched.external_pending?
  end

  # Posting is thread-safe: a worker thread hands work back, the page thread runs
  # it (single-threaded with the DOM/JS).
  def test_external_completion_is_thread_safe
    delivered = []
    workers = 4.times.map { |i| Thread.new { @sched.post_external { delivered << i } } }
    workers.each(&:join)
    @sched.advance_time(0)
    assert_equal [0, 1, 2, 3], delivered.sort
  end

  # A completion that itself schedules a timer is honored within the same advance.
  def test_external_completion_can_schedule_work
    log = []
    @sched.post_external { @sched.set_timeout(proc { log << :timer }, 0) }
    @sched.advance_time(0)
    assert_equal([:timer], log)
  end

  # A timer callback that raises propagates by default (no handler) — genuine
  # host bugs must surface rather than being silently swallowed.
  def test_timer_callback_error_propagates_without_a_handler
    @sched.set_timeout(proc { raise "boom" }, 0)
    err = assert_raises(RuntimeError) { @sched.advance_time(0) }
    assert_equal("boom", err.message)
  end

  # With a handler that swallows the error, dispatch does not escape and the
  # offending timer is dropped (so a self-rescheduling interval cannot re-fire
  # and re-stall every tick). Models the JS runtime swallowing a runaway-loop
  # execution-timeout interrupt.
  def test_timer_error_handler_swallows_and_drops_the_timer
    seen = []
    @sched.timer_error_handler = ->(e, _timer) { seen << e.message; true }
    runs = [0]
    @sched.set_interval(proc { runs[0] += 1; raise "runaway" }, 10)

    @sched.advance_time(10) # fires once, raises, swallowed + dropped
    assert_equal(1, runs[0])
    assert_equal(["runaway"], seen)

    @sched.advance_time(100) # dropped interval must not fire again
    assert_equal(1, runs[0], "interval was dropped after its callback raised")
  end

  # A handler that declines (returns falsy) re-raises — the runtime uses this to
  # let real bugs through while swallowing only the timeout interrupt.
  def test_timer_error_handler_declining_reraises
    @sched.timer_error_handler = ->(_e, _timer) { false }
    @sched.set_timeout(proc { raise "still fatal" }, 0)
    assert_raises(RuntimeError) { @sched.advance_time(0) }
  end
end
