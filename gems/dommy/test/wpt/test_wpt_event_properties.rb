# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Event properties not covered by
# test/wpt/test_wpt_events.rb (which exercises construction, dispatch,
# propagation, and listener options). This file targets:
#
#   - composedPath() return value across the dispatch path
#   - eventPhase transitions (NONE -> AT_TARGET -> BUBBLING_PHASE)
#   - timeStamp property (Float, positive, monotonic)
#
# WPT: dom/events/Event-composedPath.html,
#      dom/events/EventTarget-dispatchEvent.html,
#      dom/events/Event-timestamp-cross-realm-getter.html

class TestWPTEventComposedPath < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><span id='inner'></span></div>")
    @outer = @win.document.get_element_by_id("outer")
    @inner = @win.document.get_element_by_id("inner")
  end

  def test_composed_path_is_array
    ev = Dommy::Event.new("click")
    @inner.dispatch_event(ev)
    assert_kind_of(Array, ev.__js_call__("composedPath", []))
  end

  def test_composed_path_includes_target
    captured = nil
    @inner.add_event_listener("click") { |e| captured = e.__js_call__("composedPath", []) }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_includes(captured, @inner)
  end

  def test_composed_path_includes_ancestors_when_bubbling
    captured = nil
    @inner.add_event_listener("click") { |e| captured = e.__js_call__("composedPath", []) }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_includes(captured, @outer)
  end

  def test_composed_path_starts_with_target
    captured = nil
    @inner.add_event_listener("click") { |e| captured = e.__js_call__("composedPath", []) }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(@inner, captured.first)
  end

  def test_composed_path_is_same_at_each_listener
    paths = []
    @inner.add_event_listener("click") { |e| paths << e.__js_call__("composedPath", []) }
    @outer.add_event_listener("click") { |e| paths << e.__js_call__("composedPath", []) }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    # composedPath() is the same array across the entire dispatch.
    assert_equal(paths[0], paths[1])
  end
end

class TestWPTEventPhaseTransitions < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><span id='inner'></span></div>")
    @outer = @win.document.get_element_by_id("outer")
    @inner = @win.document.get_element_by_id("inner")
  end

  # Dommy implements three phases: NONE (0), AT_TARGET (2),
  # BUBBLING_PHASE (3). Capturing phase (1) is not implemented.

  def test_event_phase_is_none_before_dispatch
    ev = Dommy::Event.new("click")
    assert_equal(0, ev.__js_get__("eventPhase"))
  end

  def test_event_phase_is_at_target_during_target_listener
    captured = nil
    @inner.add_event_listener("click") { |e| captured = e.__js_get__("eventPhase") }
    @inner.dispatch_event(Dommy::Event.new("click"))
    assert_equal(2, captured)
  end

  def test_event_phase_is_bubbling_during_ancestor_listener
    captured = nil
    @outer.add_event_listener("click") { |e| captured = e.__js_get__("eventPhase") }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(3, captured)
  end

  def test_event_phase_resets_to_none_after_dispatch
    # WHATWG: after dispatch completes, eventPhase reverts to NONE.
    ev = Dommy::Event.new("click")
    @inner.dispatch_event(ev)
    assert_equal(0, ev.__js_get__("eventPhase"))
  end

  def test_current_target_resets_to_nil_after_dispatch
    # WHATWG: currentTarget reverts to null after dispatch.
    ev = Dommy::Event.new("click")
    @inner.dispatch_event(ev)
    assert_nil(ev.__js_get__("currentTarget"))
  end
end

class TestWPTEventTimeStamp < Minitest::Test
  def test_time_stamp_is_a_float
    ev = Dommy::Event.new("foo")
    assert_kind_of(Float, ev.__js_get__("timeStamp"))
  end

  def test_time_stamp_is_positive
    ev = Dommy::Event.new("foo")
    assert(ev.__js_get__("timeStamp") > 0)
  end

  def test_time_stamp_increases_with_real_time
    # Spec: timeStamp is a DOMHighResTimeStamp captured at construction.
    # Two events constructed at distinct moments must have distinct
    # (later > earlier) timestamps.
    first = Dommy::Event.new("foo").__js_get__("timeStamp")
    sleep 0.001
    second = Dommy::Event.new("foo").__js_get__("timeStamp")
    assert(second > first)
  end

  def test_time_stamp_is_set_at_construction_not_dispatch
    # The spec mandates timeStamp is fixed at construction. Dispatch
    # must not mutate it. Verify by reading before and after dispatch.
    target = Dommy::StandaloneEventTarget.new
    ev = Dommy::Event.new("foo")
    before = ev.__js_get__("timeStamp")
    target.dispatch_event(ev)
    after = ev.__js_get__("timeStamp")
    assert_equal(before, after)
  end
end
