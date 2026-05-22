# frozen_string_literal: true

require_relative "test_helper"

class TestTouchClipboardEvents < Minitest::Test
  include DommyTestHelper

  # --- Touch -------------------------------------------------------

  def test_touch_basic_attributes
    target = make_window("<div id='t'></div>").document.query_selector("#t")
    touch = Dommy::Touch.new(
      "identifier" => 1,
      "target" => target,
      "clientX" => 100,
      "clientY" => 200,
      "force" => 0.5
    )
    assert_equal(1, touch.identifier)
    assert_same(target, touch.target)
    assert_equal(100.0, touch.client_x)
    assert_equal(200.0, touch.client_y)
    assert_equal(0.5, touch.force)
  end

  def test_touch_page_defaults_to_client
    touch = Dommy::Touch.new("clientX" => 50, "clientY" => 60)
    assert_equal(50.0, touch.page_x)
    assert_equal(60.0, touch.page_y)
  end

  def test_touch_js_bridge
    touch = Dommy::Touch.new("identifier" => 7, "clientX" => 10, "radiusX" => 3.5)
    assert_equal(7, touch.__js_get__("identifier"))
    assert_equal(10.0, touch.__js_get__("clientX"))
    assert_equal(3.5, touch.__js_get__("radiusX"))
  end

  def test_window_exposes_touch_constructor
    win = make_window
    ctor = win.__js_get__("Touch")
    touch = ctor.__js_new__([{"identifier" => 99, "clientX" => 1}])
    assert_kind_of(Dommy::Touch, touch)
    assert_equal(99, touch.identifier)
  end

  # --- TouchList ---------------------------------------------------

  def test_touch_list_basics
    touches = [Dommy::Touch.new("identifier" => 1), Dommy::Touch.new("identifier" => 2)]
    list = Dommy::TouchList.new(touches)
    assert_equal(2, list.length)
    assert_equal(1, list[0].identifier)
    assert_equal(2, list.item(1).identifier)
    assert_nil(list[5])
    assert_equal([1, 2], list.map(&:identifier))
    assert_equal(2, list.__js_get__("length"))
    assert_kind_of(Dommy::Touch, list.__js_get__(0))
  end

  # --- TouchEvent --------------------------------------------------

  def test_touch_event_carries_lists
    win = make_window("<div id='t'></div>")
    target = win.document.query_selector("#t")
    t1 = Dommy::Touch.new("identifier" => 1, "target" => target)
    t2 = Dommy::Touch.new("identifier" => 2, "target" => target)

    ev = Dommy::TouchEvent.new(
      "touchstart",
      "touches" => [t1, t2],
      "targetTouches" => [t1],
      "changedTouches" => [t1],
      "ctrlKey" => true
    )

    assert_kind_of(Dommy::Event, ev)
    assert_equal("touchstart", ev.type)
    assert_kind_of(Dommy::TouchList, ev.touches)
    assert_equal(2, ev.touches.length)
    assert_equal(1, ev.target_touches.length)
    assert_equal(1, ev.changed_touches.length)
    assert_equal(true, ev.__js_get__("ctrlKey"))
  end

  def test_touch_event_defaults_to_empty_lists
    ev = Dommy::TouchEvent.new("touchend")
    assert_equal(0, ev.touches.length)
    assert_equal(0, ev.target_touches.length)
    assert_equal(0, ev.changed_touches.length)
  end

  def test_touch_event_dispatched_to_target
    win = make_window("<div id='t'></div>")
    target = win.document.query_selector("#t")
    received = nil
    target.add_event_listener("touchstart", proc { |e| received = e })

    touch = Dommy::Touch.new("identifier" => 1, "target" => target, "clientX" => 5)
    target.dispatch_event(
      Dommy::TouchEvent.new(
        "touchstart",
        "touches" => [touch],
        "changedTouches" => [touch]
      )
    )

    refute_nil(received)
    assert_equal(1, received.changed_touches.length)
    assert_equal(5.0, received.changed_touches[0].client_x)
  end

  def test_window_exposes_touch_event_constructor
    win = make_window
    ctor = win.__js_get__("TouchEvent")
    ev = ctor.__js_new__(["touchmove", {"touches" => []}])
    assert_kind_of(Dommy::TouchEvent, ev)
  end

  # --- ClipboardEvent ---------------------------------------------

  def test_clipboard_event_carries_data_transfer
    dt = Dommy::DataTransfer.new
    dt.set_data("text/plain", "Hello")
    ev = Dommy::ClipboardEvent.new("copy", "clipboardData" => dt)

    assert_kind_of(Dommy::Event, ev)
    assert_equal("copy", ev.type)
    assert_same(dt, ev.clipboard_data)
    assert_same(dt, ev.__js_get__("clipboardData"))
  end

  def test_clipboard_event_no_data
    ev = Dommy::ClipboardEvent.new("cut")
    assert_nil(ev.clipboard_data)
  end

  def test_clipboard_event_dispatched_with_paste_data
    win = make_window("<textarea id='t'></textarea>")
    target = win.document.query_selector("#t")
    pasted_text = nil
    target.add_event_listener(
      "paste",
      proc { |e|
        pasted_text = e.__js_get__("clipboardData").get_data("text/plain")
      }
    )

    dt = Dommy::DataTransfer.new
    dt.set_data("text/plain", "Pasted!")
    target.dispatch_event(Dommy::ClipboardEvent.new("paste", "clipboardData" => dt))

    assert_equal("Pasted!", pasted_text)
  end

  def test_window_exposes_clipboard_event_constructor
    win = make_window
    ctor = win.__js_get__("ClipboardEvent")
    ev = ctor.__js_new__(["paste", {}])
    assert_kind_of(Dommy::ClipboardEvent, ev)
  end
end
