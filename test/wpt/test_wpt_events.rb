# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Event and EventTarget.
class TestWPTEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><div id='inner'></div></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @inner = @doc.get_element_by_id("inner")
  end

  # ---- Event constructor ----
  # WPT: dom/events/Event-constructors.any.js

  def test_event_constructor_type
    ev = Dommy::Event.new("click")
    assert_equal("click", ev.__js_get__("type"))
  end

  def test_event_constructor_default_bubbles_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("bubbles"))
  end

  def test_event_constructor_default_cancelable_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("cancelable"))
  end

  def test_event_constructor_default_composed_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("composed"))
  end

  def test_event_constructor_init_bubbles
    ev = Dommy::Event.new("click", "bubbles" => true)
    assert_equal(true, ev.__js_get__("bubbles"))
  end

  def test_event_constructor_init_cancelable
    ev = Dommy::Event.new("click", "cancelable" => true)
    assert_equal(true, ev.__js_get__("cancelable"))
  end

  def test_event_constructor_init_composed
    ev = Dommy::Event.new("click", "composed" => true)
    assert_equal(true, ev.__js_get__("composed"))
  end

  # ---- Event.cancelBubble / stopPropagation ----
  # WPT: dom/events/Event-cancelBubble.html

  def test_cancelBubble_initial_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("cancelBubble"))
  end

  def test_stopPropagation_sets_cancelBubble
    ev = Dommy::Event.new("click")
    ev.__js_call__("stopPropagation", [])
    assert_equal(true, ev.__js_get__("cancelBubble"))
  end

  def test_cancelBubble_truthy_assignment_stops_propagation
    ev = Dommy::Event.new("click")
    ev.__js_set__("cancelBubble", true)
    assert_equal(true, ev.__js_get__("cancelBubble"))
  end

  # ---- preventDefault ----
  # WPT: dom/events/Event-defaultPrevented.html

  def test_defaultPrevented_initial_false
    ev = Dommy::Event.new("click")
    assert_equal(false, ev.__js_get__("defaultPrevented"))
  end

  def test_preventDefault_on_cancelable
    ev = Dommy::Event.new("click", "cancelable" => true)
    ev.__js_call__("preventDefault", [])
    assert_equal(true, ev.__js_get__("defaultPrevented"))
  end

  def test_preventDefault_on_non_cancelable_noop
    ev = Dommy::Event.new("click", "cancelable" => false)
    ev.__js_call__("preventDefault", [])
    assert_equal(false, ev.__js_get__("defaultPrevented"))
  end

  # ---- Event dispatch with no bubbles ----
  # WPT: dom/events/Event-dispatch-bubbles-false.html

  def test_dispatch_no_bubbles_stops_at_target
    parent_seen = false
    @outer.add_event_listener("custom") { parent_seen = true }
    @inner.dispatch_event(Dommy::Event.new("custom", "bubbles" => false))
    refute(parent_seen)
  end

  # ---- Event dispatch with bubbles ----
  # WPT: dom/events/Event-dispatch-bubbles-true.html

  def test_dispatch_bubbles_reaches_parent
    parent_seen = false
    @outer.add_event_listener("custom") { parent_seen = true }
    @inner.dispatch_event(Dommy::Event.new("custom", "bubbles" => true))
    assert(parent_seen)
  end

  # ---- Event.target / currentTarget ----

  def test_target_is_dispatch_node
    captured = nil
    @inner.add_event_listener("click") { |e| captured = e.__js_get__("target") }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_same(@inner, captured)
  end

  def test_currentTarget_changes_per_listener
    seen = []
    @inner.add_event_listener("click") { |e| seen << e.__js_get__("currentTarget") }
    @outer.add_event_listener("click") { |e| seen << e.__js_get__("currentTarget") }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal([@inner, @outer], seen)
  end

  # ---- stopPropagation during bubble ----
  # WPT: dom/events/Event-dispatch-propagation-stopped.html

  def test_stopPropagation_during_bubble
    parent_seen = false
    @outer.add_event_listener("click") { parent_seen = true }
    @inner.add_event_listener("click") { |e| e.__js_call__("stopPropagation", []) }
    @inner.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    refute(parent_seen)
  end

  # ---- stopImmediatePropagation ----
  # WPT: dom/events/Event-dispatch-multiple-stopPropagation.html

  def test_stopImmediatePropagation_blocks_same_target
    seen = []
    @inner.add_event_listener("click") { seen << :first }
    @inner.add_event_listener("click") { |e|
      e.__js_call__("stopImmediatePropagation", [])
      seen << :second
    }
    @inner.add_event_listener("click") { seen << :third }
    @inner.dispatch_event(Dommy::Event.new("click"))
    assert_equal([:first, :second], seen)
  end

  # ---- AddEventListenerOptions once ----
  # WPT: dom/events/AddEventListenerOptions-once.any.js

  def test_addEventListener_once_fires_once
    count = 0
    @inner.add_event_listener("click", proc { count += 1 }, {"once" => true})
    @inner.click
    @inner.click
    @inner.click
    assert_equal(1, count)
  end

  # ---- AddEventListenerOptions signal ----
  # WPT: dom/events/AddEventListenerOptions-signal.any.js

  def test_addEventListener_signal_removes_on_abort
    ctrl = Dommy::AbortController.new
    count = 0
    @inner.add_event_listener("click", proc { count += 1 }, {"signal" => ctrl.signal})
    @inner.click
    assert_equal(1, count)
    ctrl.__js_call__("abort", [])
    @inner.click
    assert_equal(1, count)
  end

  def test_addEventListener_already_aborted_signal_skips_registration
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", [])
    count = 0
    @inner.add_event_listener("click", proc { count += 1 }, {"signal" => ctrl.signal})
    @inner.click
    assert_equal(0, count)
  end

  # ---- removeEventListener ----

  def test_removeEventListener_stops_invocation
    count = 0
    handler = proc { count += 1 }
    @inner.add_event_listener("click", handler)
    @inner.click
    @inner.remove_event_listener("click", handler)
    @inner.click
    assert_equal(1, count)
  end

  # ---- handleEvent object ----
  # WPT: dom/events/EventListener-handleEvent.html

  def test_handleEvent_object_listener
    received = nil
    obj = Class
      .new {
        define_method(:handle_event) { |e| received = e.__js_get__("type") }
      }
      .new
    @inner.add_event_listener("click", obj)
    @inner.click
    assert_equal("click", received)
  end

  # ---- dispatchEvent return value ----

  def test_dispatchEvent_returns_true_when_no_preventDefault
    ev = Dommy::Event.new("click", "cancelable" => true)
    result = @inner.dispatch_event(ev)
    assert_equal(true, result)
  end

  def test_dispatchEvent_returns_false_when_preventDefault
    @inner.add_event_listener("click") { |e| e.__js_call__("preventDefault", []) }
    ev = Dommy::Event.new("click", "cancelable" => true)
    result = @inner.dispatch_event(ev)
    assert_equal(false, result)
  end

  # ---- CustomEvent ----
  # WPT: dom/events/CustomEvent.html

  def test_customEvent_detail
    ev = Dommy::CustomEvent.new("ping", "detail" => {"n" => 42})
    assert_equal({"n" => 42}, ev.__js_get__("detail"))
  end

  def test_customEvent_default_detail_nil
    ev = Dommy::CustomEvent.new("ping")
    assert_nil(ev.__js_get__("detail"))
  end

  # ---- Event constants on instance ----
  # WPT: dom/events/Event-constants.html

  def test_event_phase_constants_via_eventPhase
    # NONE = 0, AT_TARGET = 2, BUBBLING_PHASE = 3. We don't implement
    # CAPTURING_PHASE (1) by design. Verify accessible values.
    ev = Dommy::Event.new("click")
    assert_equal(0, ev.__js_get__("eventPhase"))
  end
end
