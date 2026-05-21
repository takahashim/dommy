# frozen_string_literal: true

require_relative "test_helper"

class TestEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><button id='btn'>X</button></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @btn = @doc.get_element_by_id("btn")
  end

  def test_add_event_listener_block
    fired = false
    @btn.on("click") { fired = true }
    @btn.click
    assert(fired)
  end

  def test_listener_receives_event
    captured = nil
    @btn.on("click") { |ev| captured = ev }
    @btn.click
    refute_nil(captured)
    assert_equal("click", captured.__js_get__("type"))
  end

  def test_event_bubbles_to_parent
    parent_clicks = 0
    @outer.on("click") { parent_clicks += 1 }
    @btn.click
    assert_equal(1, parent_clicks)
  end

  def test_stop_propagation
    parent_clicks = 0
    @outer.on("click") { parent_clicks += 1 }
    @btn.on("click") { |ev| ev.__js_call__("stopPropagation", []) }
    @btn.click
    assert_equal(0, parent_clicks)
  end

  def test_prevent_default_flips_flag
    ev = Dommy::MouseEvent.new("click", "bubbles" => true, "cancelable" => true)
    captured = nil
    @btn.on("click") { |e|
      e.__js_call__("preventDefault", [])
      captured = e
    }
    @btn.dispatch_event(ev)
    assert_equal(true, captured.__js_get__("defaultPrevented"))
  end

  def test_remove_event_listener
    fired = 0
    listener = @btn.on("click") { fired += 1 }
    @btn.click
    @btn.remove_event_listener("click", listener)
    @btn.click
    assert_equal(1, fired)
  end

  def test_custom_event_detail
    received = nil
    @doc.body.add_event_listener("ping") { |e| received = e.__js_get__("detail") }
    ev = Dommy::CustomEvent.new("ping", "bubbles" => true, "detail" => {"n" => 42})
    @btn.dispatch_event(ev)
    assert_equal({"n" => 42}, received)
  end

  def test_keyboard_event_modifiers
    ev = Dommy::KeyboardEvent.new("keydown", "key" => "Enter", "ctrlKey" => true)
    assert_equal("Enter", ev.__js_get__("key"))
    assert_equal(true, ev.__js_get__("ctrlKey"))
    assert_equal(false, ev.__js_get__("shiftKey"))
  end
end
