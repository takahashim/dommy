# frozen_string_literal: true

require_relative "test_helper"

class TestOnHandlers < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  def test_onclick_setter_registers_listener
    seen = false
    @btn[:onclick] = proc { seen = true }
    @btn.click
    assert(seen)
  end

  def test_onclick_getter_returns_handler
    handler = proc { }
    @btn[:onclick] = handler
    assert_same(handler, @btn[:onclick])
  end

  def test_onclick_overwrite_removes_previous
    counts = [0, 0]
    @btn[:onclick] = proc { counts[0] += 1 }
    @btn[:onclick] = proc { counts[1] += 1 }
    @btn.click
    assert_equal(0, counts[0])
    assert_equal(1, counts[1])
  end

  def test_onclick_set_to_nil_removes
    fired = 0
    @btn[:onclick] = proc { fired += 1 }
    @btn.click
    @btn[:onclick] = nil
    @btn.click
    assert_equal(1, fired)
  end

  def test_onkeydown_handler
    seen = nil
    @btn[:onkeydown] = proc { |e| seen = e.__js_get__("key") }
    @btn.dispatch_event(Dommy::KeyboardEvent.new("keydown", "key" => "Enter"))
    assert_equal("Enter", seen)
  end

  def test_oninput_handler
    seen = false
    @btn[:oninput] = proc { seen = true }
    @btn.dispatch_event(Dommy::Event.new("input"))
    assert(seen)
  end

  # --- event handler processing: return value cancels (onclick="return false") ---

  def test_handler_returning_false_cancels_the_event
    @btn[:onclick] = proc { false }
    event = Dommy::MouseEvent.new("click", "cancelable" => true)
    not_cancelled = @btn.dispatch_event(event)

    refute(not_cancelled, "a false return cancels")
    assert(event.__js_get__("defaultPrevented"))
  end

  def test_handler_returning_truthy_does_not_cancel
    @btn[:onclick] = proc { true }
    event = Dommy::MouseEvent.new("click", "cancelable" => true)

    assert(@btn.dispatch_event(event))
    refute(event.__js_get__("defaultPrevented"))
  end

  def test_addeventlistener_return_value_is_ignored
    # Only event-handler (onX) listeners process the return value; a plain
    # addEventListener listener returning false does NOT cancel.
    @btn.add_event_listener("click", proc { false })
    event = Dommy::MouseEvent.new("click", "cancelable" => true)

    assert(@btn.dispatch_event(event), "addEventListener return value is ignored")
    refute(event.__js_get__("defaultPrevented"))
  end

  # --- HTMLBodyElement window-reflecting IDL handlers (body.onload = fn) ---

  def test_body_onload_idl_reflects_to_the_window
    fired = []
    @doc.body[:onload] = proc { |e| fired << e.__js_get__("currentTarget") }
    # load fires on the WINDOW; the body.onload handler must run there.
    @win.dispatch_event(Dommy::Event.new("load"))

    assert_equal([@win], fired, "body.onload reflects onto the window")
    assert_same(@win.__js_get__("onload"), @doc.body[:onload], "reads back through the window")
  end

  def test_body_onclick_stays_on_the_body
    fired = 0
    @doc.body[:onclick] = proc { fired += 1 }
    @doc.body.dispatch_event(Dommy::MouseEvent.new("click"))
    assert_equal(1, fired, "a non-reflected handler stays on the body")
  end
end
