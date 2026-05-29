# frozen_string_literal: true

require_relative "test_helper"

# Round out EventTarget coverage with the remaining happy-dom edges:
# TypeError on non-Event, multiple bindings with `once`, listener
# scope, and arbitrary on* keys.
class TestEventTargetExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  def test_dispatch_event_raises_for_non_event
    assert_raises(TypeError) { @btn.dispatch_event("not-an-event") }
    assert_raises(TypeError) { @btn.dispatch_event({}) }
  end

  def test_dispatch_event_accepts_nil_returns_true
    assert_equal(true, @btn.dispatch_event(nil))
  end

  def test_once_option_fires_once_then_removes
    count = 0
    @btn.add_event_listener("click", proc { count += 1 }, {"once" => true})
    @btn.click
    @btn.click
    @btn.click
    assert_equal(1, count)
  end

  def test_once_with_multiple_distinct_listeners
    fired = []
    @btn.add_event_listener("click", proc { fired << :a }, {"once" => true})
    @btn.add_event_listener("click", proc { fired << :b }, {"once" => true})
    @btn.click
    assert_equal([:a, :b], fired)
    @btn.click
    # both auto-removed
    assert_equal([:a, :b], fired)
  end

  def test_arbitrary_event_type_does_not_fire_on_unrelated_dispatch
    # Setting el.onweird = fn registers as listener for "weird" events.
    # Dispatching a "click" should NOT invoke the weird handler.
    fired = false
    @btn[:onweird] = proc { fired = true }
    @btn.click
    refute(fired)
  end

  def test_arbitrary_on_handler_fires_when_dispatched
    # If a user does dispatch the matching event, the handler fires.
    seen = false
    @btn[:oncustom] = proc { seen = true }
    @btn.dispatch_event(Dommy::Event.new("custom"))
    assert(seen)
  end

  def test_custom_event_listener_via_constructor
    seen_detail = nil
    @btn.add_event_listener("ping", proc { |e| seen_detail = e.__js_get__("detail") })
    @btn.dispatch_event(Dommy::CustomEvent.new("ping", "detail" => "hi"))
    assert_equal("hi", seen_detail)
  end

  def test_remove_event_listener_with_unknown_listener_is_noop
    @btn.remove_event_listener("click", proc { })
    # No exception, no crash.
    assert(true)
  end

  def test_remove_event_listener_unknown_type_is_noop
    @btn.remove_event_listener("never-registered", proc { })
    assert(true)
  end
end
