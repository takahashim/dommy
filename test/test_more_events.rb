# frozen_string_literal: true

require_relative "test_helper"

# Tests CompositionEvent, WheelEvent, FocusEvent, BeforeUnloadEvent.
class TestMoreEvents < Minitest::Test
  include DommyTestHelper

  # --- CompositionEvent --------------------------------------------

  def test_composition_event_data
    ev = Dommy::CompositionEvent.new("compositionupdate", "data" => "あ")
    assert_kind_of(Dommy::Event, ev)
    assert_equal("compositionupdate", ev.type)
    assert_equal("あ", ev.data)
    assert_equal("あ", ev.__js_get__("data"))
  end

  def test_composition_event_empty_data
    ev = Dommy::CompositionEvent.new("compositionstart")
    assert_equal("", ev.data)
  end

  def test_composition_event_dispatch
    win = make_window("<input id='x'/>")
    input = win.document.query_selector("#x")
    received = nil
    input.add_event_listener("compositionend", proc { |e| received = e })
    input.dispatch_event(Dommy::CompositionEvent.new("compositionend", "data" => "完成"))
    assert_equal("完成", received.data)
  end

  def test_window_exposes_composition_event_constructor
    win = make_window
    ctor = win.__js_get__("CompositionEvent")
    ev = ctor.__js_new__(["compositionupdate", {"data" => "x"}])
    assert_kind_of(Dommy::CompositionEvent, ev)
  end

  # --- WheelEvent -------------------------------------------------

  def test_wheel_event_deltas
    ev = Dommy::WheelEvent.new(
      "wheel",
      "deltaX" => 0,
      "deltaY" => -100,
      "deltaZ" => 0,
      "deltaMode" => 0
    )
    assert_kind_of(Dommy::MouseEvent, ev)
    assert_equal(0.0, ev.delta_x)
    assert_equal(-100.0, ev.delta_y)
    assert_equal(0.0, ev.delta_z)
    assert_equal(0, ev.delta_mode)
  end

  def test_wheel_event_inherits_mouse_coords
    ev = Dommy::WheelEvent.new("wheel", "clientX" => 50, "clientY" => 60, "deltaY" => 10)
    assert_equal(50, ev.__js_get__("clientX"))
    assert_equal(60, ev.__js_get__("clientY"))
    assert_equal(10.0, ev.__js_get__("deltaY"))
  end

  def test_wheel_event_delta_mode_constants
    assert_equal(0, Dommy::WheelEvent::DOM_DELTA_PIXEL)
    assert_equal(1, Dommy::WheelEvent::DOM_DELTA_LINE)
    assert_equal(2, Dommy::WheelEvent::DOM_DELTA_PAGE)
  end

  def test_wheel_event_dispatched
    win = make_window("<div id='scroll'></div>")
    target = win.document.query_selector("#scroll")
    received = nil
    target.add_event_listener("wheel", proc { |e| received = e })
    target.dispatch_event(Dommy::WheelEvent.new("wheel", "deltaY" => 100))
    assert_equal(100.0, received.delta_y)
  end

  def test_window_exposes_wheel_event_constructor
    win = make_window
    ctor = win.__js_get__("WheelEvent")
    ev = ctor.__js_new__(["wheel", {"deltaY" => 50}])
    assert_kind_of(Dommy::WheelEvent, ev)
  end

  # --- FocusEvent -------------------------------------------------

  def test_focus_event_related_target
    win = make_window("<input id='a'/><input id='b'/>")
    a = win.document.query_selector("#a")

    ev = Dommy::FocusEvent.new("focus", "relatedTarget" => a)
    assert_kind_of(Dommy::Event, ev)
    assert_same(a, ev.related_target)
    assert_same(a, ev.__js_get__("relatedTarget"))
  end

  def test_focus_event_default_related_target_nil
    ev = Dommy::FocusEvent.new("blur")
    assert_nil(ev.related_target)
  end

  def test_focus_event_dispatched
    win = make_window("<input id='a'/><input id='b'/>")
    a = win.document.query_selector("#a")
    b = win.document.query_selector("#b")

    received = nil
    a.add_event_listener("blur", proc { |e| received = e })
    a.dispatch_event(Dommy::FocusEvent.new("blur", "relatedTarget" => b))
    assert_same(b, received.related_target)
  end

  def test_window_exposes_focus_event_constructor
    win = make_window
    ctor = win.__js_get__("FocusEvent")
    ev = ctor.__js_new__(["focus", {}])
    assert_kind_of(Dommy::FocusEvent, ev)
  end

  # --- BeforeUnloadEvent ------------------------------------------

  def test_before_unload_event_default_type
    ev = Dommy::BeforeUnloadEvent.new
    assert_equal("beforeunload", ev.type)
    assert_equal("", ev.return_value)
  end

  def test_before_unload_event_return_value
    ev = Dommy::BeforeUnloadEvent.new
    ev.return_value = "Are you sure?"
    assert_equal("Are you sure?", ev.return_value)
    assert_equal("Are you sure?", ev.__js_get__("returnValue"))
  end

  def test_before_unload_event_via_js_set
    ev = Dommy::BeforeUnloadEvent.new
    ev.__js_set__("returnValue", "Wait!")
    assert_equal("Wait!", ev.return_value)
  end

  def test_window_exposes_before_unload_event_constructor
    win = make_window
    ctor = win.__js_get__("BeforeUnloadEvent")
    ev = ctor.__js_new__([])
    assert_kind_of(Dommy::BeforeUnloadEvent, ev)
  end
end
