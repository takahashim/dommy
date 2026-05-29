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
end
