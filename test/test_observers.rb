# frozen_string_literal: true

require_relative "test_helper"

class TestObservers < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='target'></div>")
    @target = @win.document.query_selector("#target")
  end

  # --- IntersectionObserver -------------------------------------

  def test_intersection_observer_default_options
    io = Dommy::IntersectionObserver.new(proc { })
    assert_nil(io.root)
    assert_equal("0px", io.root_margin)
    assert_equal([0.0], io.thresholds)
  end

  def test_intersection_observer_observe_unobserve_disconnect
    io = Dommy::IntersectionObserver.new(proc { })
    io.observe(@target)
    assert_includes(io.observed_targets, @target)

    io.unobserve(@target)
    refute_includes(io.observed_targets, @target)

    io.observe(@target)
    io.disconnect
    assert_empty(io.observed_targets)
  end

  def test_intersection_observer_options_are_normalized
    io = Dommy::IntersectionObserver.new(proc { }, "rootMargin" => "10px", "threshold" => [0.5, 1.0])
    assert_equal("10px", io.root_margin)
    assert_equal([0.5, 1.0], io.thresholds)
  end

  def test_intersection_observer_trigger_fires_callback
    received = nil
    io = Dommy::IntersectionObserver.new(proc { |entries| received = entries })
    io.__trigger__([{"target" => @target, "isIntersecting" => true}])
    refute_nil(received)
    assert_equal(true, received.first["isIntersecting"])
  end

  def test_intersection_observer_window_constructor
    ctor = @win.__js_get__("IntersectionObserver")
    io = ctor.__js_new__([proc { }, {"threshold" => 0.5}])
    assert_kind_of(Dommy::IntersectionObserver, io)
    assert_equal([0.5], io.thresholds)
  end

  # --- ResizeObserver --------------------------------------------

  def test_resize_observer_observe_unobserve
    ro = Dommy::ResizeObserver.new(proc { })
    ro.observe(@target)
    assert_includes(ro.observed_targets, @target)
    ro.unobserve(@target)
    refute_includes(ro.observed_targets, @target)
  end

  def test_resize_observer_trigger_fires_callback
    fired = false
    ro = Dommy::ResizeObserver.new(proc { fired = true })
    ro.__trigger__([])
    assert(fired)
  end

  def test_resize_observer_window_constructor
    ctor = @win.__js_get__("ResizeObserver")
    ro = ctor.__js_new__([proc { }])
    assert_kind_of(Dommy::ResizeObserver, ro)
  end

  # --- PerformanceObserver ---------------------------------------

  def test_performance_observer_observe_sets_entry_types
    po = Dommy::PerformanceObserver.new(proc { })
    po.observe("entryTypes" => ["measure", "mark"])
    assert_equal(["measure", "mark"], po.entry_types)
  end

  def test_performance_observer_observe_single_type
    po = Dommy::PerformanceObserver.new(proc { })
    po.observe("type" => "measure")
    assert_equal(["measure"], po.entry_types)
  end

  def test_performance_observer_trigger
    received = nil
    po = Dommy::PerformanceObserver.new(proc { |entries| received = entries })
    po.observe("type" => "measure")
    po.__trigger__([{"name" => "x", "duration" => 5}])
    refute_nil(received)
  end

  def test_performance_observer_take_records_returns_empty
    po = Dommy::PerformanceObserver.new(proc { })
    assert_equal([], po.take_records)
  end
end
