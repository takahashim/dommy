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
    assert_raises(Dommy::Bridge::TypeError) { @btn.dispatch_event("not-an-event") }
    assert_raises(Dommy::Bridge::TypeError) { @btn.dispatch_event({}) }
  end

  def test_dispatch_event_raises_for_nil
    # WebIDL: dispatchEvent takes a non-nullable Event, so null is a TypeError
    # rather than a silent no-op.
    assert_raises(Dommy::Bridge::TypeError) { @btn.dispatch_event(nil) }
  end

  def test_dispatch_event_raises_for_an_uninitialized_event
    event = @doc.create_event("Event")
    assert_raises(Dommy::DOMException::InvalidStateError) { @btn.dispatch_event(event) }
    event.__js_call__("initEvent", ["ready", true, false])
    assert_equal(true, @btn.dispatch_event(event))
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

  def test_throwing_listener_is_isolated_and_dispatch_continues
    # WHATWG: a listener's exception is reported and dispatch keeps going — it
    # must not escape dispatch_event (a synthetic click from the host would
    # otherwise crash). The later listener still fires.
    fired = []
    @btn.add_event_listener("click", proc { fired << :first })
    @btn.add_event_listener("click", proc { raise "boom" })
    @btn.add_event_listener("click", proc { fired << :third })
    assert_equal(true, @btn.dispatch_event(Dommy::Event.new("click")))
    assert_equal(%i[first third], fired)
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

# HTML compiles an `on*` content attribute the first time a matching event
# reaches its element, so a node that arrived by `cloneNode` / `innerHTML` /
# `setAttribute` — after the boot-time wiring pass — still gets its handler.
class TestLazyInlineHandlerWiring < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @wired = 0
    @doc.inline_handler_wirer = -> { @wired += 1 }
    @el = @doc.create_element("div")
    @doc.body.append_child(@el)
  end

  def test_an_element_without_an_on_attribute_never_wires
    @el.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(0, @wired)
  end

  def test_the_first_matching_event_triggers_the_wiring_pass
    @el.set_attribute("onclick", "noop()")
    @el.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(1, @wired)
  end

  def test_a_second_event_of_the_same_type_does_not_wire_again
    @el.set_attribute("onclick", "noop()")
    2.times { @el.dispatch_event(Dommy::Event.new("click", "bubbles" => true)) }
    assert_equal(1, @wired)
  end

  def test_an_unrelated_event_type_does_not_wire
    @el.set_attribute("onclick", "noop()")
    @el.dispatch_event(Dommy::Event.new("focus", "bubbles" => true))
    assert_equal(0, @wired)
  end

  # An element the event only passes through wires its own handler too.
  def test_an_ancestor_on_the_bubble_path_wires_as_well
    @el.set_attribute("onclick", "noop()")
    child = @doc.create_element("span")
    @el.append_child(child)
    child.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(1, @wired)
  end

  def test_no_wirer_means_no_work
    @doc.inline_handler_wirer = nil
    @el.set_attribute("onclick", "noop()")
    @el.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(0, @wired)
  end
end
