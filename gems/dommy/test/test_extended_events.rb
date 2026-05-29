# frozen_string_literal: true

require_relative "test_helper"

class TestExtendedEvents < Minitest::Test
  include DommyTestHelper

  # --- InputEvent -------------------------------------------------

  def test_input_event_basic
    ev = Dommy::InputEvent.new("input", "data" => "Hello", "inputType" => "insertText")
    assert_kind_of(Dommy::Event, ev)
    assert_equal("input", ev.type)
    assert_equal("Hello", ev.__js_get__("data"))
    assert_equal("insertText", ev.__js_get__("inputType"))
    assert_equal(false, ev.__js_get__("isComposing"))
  end

  def test_input_event_with_composing
    ev = Dommy::InputEvent.new(
      "beforeinput",
      "data" => "あ",
      "inputType" => "insertCompositionText",
      "isComposing" => true
    )
    assert_equal(true, ev.__js_get__("isComposing"))
  end

  def test_input_event_dispatched
    win = make_window("<input id='x'/>")
    input = win.document.query_selector("#x")
    received = nil
    input.add_event_listener("input", proc { |e| received = e })
    input.dispatch_event(Dommy::InputEvent.new("input", "data" => "x", "inputType" => "insertText"))
    refute_nil(received)
    assert_equal("x", received.__js_get__("data"))
  end

  def test_window_exposes_input_event_constructor
    win = make_window
    ctor = win.__js_get__("InputEvent")
    ev = ctor.__js_new__(["input", {"data" => "Y"}])
    assert_kind_of(Dommy::InputEvent, ev)
    assert_equal("Y", ev.__js_get__("data"))
  end

  # --- PointerEvent -----------------------------------------------

  def test_pointer_event_inherits_mouse_event
    ev = Dommy::PointerEvent.new(
      "pointerdown",
      "pointerId" => 1,
      "pointerType" => "mouse",
      "clientX" => 100,
      "clientY" => 200
    )
    assert_kind_of(Dommy::MouseEvent, ev)
    assert_kind_of(Dommy::Event, ev)
    assert_equal(1, ev.__js_get__("pointerId"))
    assert_equal("mouse", ev.__js_get__("pointerType"))
    assert_equal(100, ev.__js_get__("clientX"))
    assert_equal(200, ev.__js_get__("clientY"))
  end

  def test_pointer_event_defaults
    ev = Dommy::PointerEvent.new("pointerup")
    assert_equal(0, ev.__js_get__("pointerId"))
    assert_equal("mouse", ev.__js_get__("pointerType"))
    assert_equal(0.0, ev.__js_get__("pressure"))
    assert_equal(1.0, ev.__js_get__("width"))
    assert_equal(1.0, ev.__js_get__("height"))
    assert_equal(false, ev.__js_get__("isPrimary"))
  end

  def test_pointer_event_full_attributes
    ev = Dommy::PointerEvent.new(
      "pointermove",
      "pointerId" => 42,
      "pointerType" => "touch",
      "pressure" => 0.5,
      "tangentialPressure" => 0.1,
      "width" => 2,
      "height" => 3,
      "tiltX" => 10,
      "tiltY" => -5,
      "twist" => 7,
      "isPrimary" => true
    )
    assert_equal(42, ev.__js_get__("pointerId"))
    assert_equal("touch", ev.__js_get__("pointerType"))
    assert_equal(0.5, ev.__js_get__("pressure"))
    assert_equal(0.1, ev.__js_get__("tangentialPressure"))
    assert_equal(2.0, ev.__js_get__("width"))
    assert_equal(3.0, ev.__js_get__("height"))
    assert_equal(10, ev.__js_get__("tiltX"))
    assert_equal(-5, ev.__js_get__("tiltY"))
    assert_equal(7, ev.__js_get__("twist"))
    assert_equal(true, ev.__js_get__("isPrimary"))
  end

  def test_window_exposes_pointer_event_constructor
    win = make_window
    ctor = win.__js_get__("PointerEvent")
    ev = ctor.__js_new__(["pointerdown", {"pointerId" => 1}])
    assert_kind_of(Dommy::PointerEvent, ev)
  end

  # --- ProgressEvent ----------------------------------------------

  def test_progress_event_basic
    ev = Dommy::ProgressEvent.new("progress", "loaded" => 50, "total" => 100, "lengthComputable" => true)
    assert_equal(50, ev.__js_get__("loaded"))
    assert_equal(100, ev.__js_get__("total"))
    assert_equal(true, ev.__js_get__("lengthComputable"))
  end

  def test_progress_event_defaults
    ev = Dommy::ProgressEvent.new("loadend")
    assert_equal(0, ev.__js_get__("loaded"))
    assert_equal(0, ev.__js_get__("total"))
    assert_equal(false, ev.__js_get__("lengthComputable"))
  end

  def test_window_exposes_progress_event_constructor
    win = make_window
    ctor = win.__js_get__("ProgressEvent")
    ev = ctor.__js_new__(["progress", {"loaded" => 10}])
    assert_kind_of(Dommy::ProgressEvent, ev)
    assert_equal(10, ev.__js_get__("loaded"))
  end
end
