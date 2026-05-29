# frozen_string_literal: true

require_relative "test_helper"

class TestEventExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><span id='inner'>x</span></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @inner = @doc.get_element_by_id("inner")
  end

  def test_event_has_time_stamp
    ev = Dommy::Event.new("click")
    assert_kind_of(Float, ev.__js_get__("timeStamp"))
  end

  def test_event_composed_default_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("composed"))
  end

  def test_event_composed_init_true
    ev = Dommy::Event.new("click", "composed" => true)
    assert_equal(true, ev.__js_get__("composed"))
  end

  def test_cancel_bubble_initial_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("cancelBubble"))
  end

  def test_cancel_bubble_set_stops_propagation
    parent_seen = false
    @outer.on("click") { parent_seen = true }
    @inner.on("click") { |e| e.__js_set__("cancelBubble", true) }
    @inner.click
    refute(parent_seen)
  end

  def test_composed_path_lists_targets
    captured = nil
    @inner.on("click") { |e| captured = e.__js_call__("composedPath", []) }
    @inner.click
    refute_nil(captured)
    assert(captured.first.equal?(@inner))
  end

  def test_event_phase_at_target
    seen_phase = nil
    @inner.on("click") { |e| seen_phase = e.__js_get__("eventPhase") }
    @inner.click
    assert_equal(2, seen_phase)
  end

  def test_event_phase_bubbling
    seen_phase = nil
    @outer.on("click") { |e| seen_phase = e.__js_get__("eventPhase") }
    @inner.click
    assert_equal(3, seen_phase)
  end
end
