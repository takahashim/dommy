# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the event dispatch algorithm's ordering / re-entrancy
# rules and for the inline CSSOM declaration block.
#
# WPT: dom/events/Event-dispatch-order-at-target.html
#      dom/events/Event-dispatch-listener-order.window.js
#      dom/events/Event-stopPropagation-cancel-bubbling.html
#      dom/events/EventTarget-dispatchEvent.html
#      dom/events/Event-dispatch-on-disabled-elements.html
#      css/cssom/css-style-attr-decl-block.html
class TestWPTDispatchOrder < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><button id='btn'>X</button></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @btn = @doc.get_element_by_id("btn")
  end

  # ---- AT_TARGET ordering ----
  # The target is visited in BOTH the capturing and the bubbling pass, so its
  # capture listeners run first no matter the registration order.

  def test_at_target_capture_listener_runs_before_bubble_listener
    seen = []
    @btn.add_event_listener("click", nil, nil) { seen << :bubble }
    @btn.add_event_listener("click", nil, {"capture" => true}) { seen << :capture }
    @btn.dispatch_event(Dommy::Event.new("click"))
    assert_equal(%i[capture bubble], seen)
  end

  def test_at_target_event_phase_is_at_target_for_both_kinds
    phases = []
    @btn.add_event_listener("click", nil, nil) { |e| phases << e.__js_get__("eventPhase") }
    @btn.add_event_listener("click", nil, {"capture" => true}) { |e| phases << e.__js_get__("eventPhase") }
    @btn.dispatch_event(Dommy::Event.new("click"))
    assert_equal([Dommy::Event::AT_TARGET, Dommy::Event::AT_TARGET], phases)
  end

  def test_full_propagation_order_across_ancestors
    seen = []
    @outer.add_event_listener("click", nil, {"capture" => true}) { seen << :outer_capture }
    @outer.add_event_listener("click", nil, nil) { seen << :outer_bubble }
    @btn.add_event_listener("click", nil, nil) { seen << :target_bubble }
    @btn.add_event_listener("click", nil, {"capture" => true}) { seen << :target_capture }
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(%i[outer_capture target_capture target_bubble outer_bubble], seen)
  end

  def test_stop_propagation_in_target_capture_skips_target_bubble
    seen = []
    @btn.add_event_listener("click", nil, {"capture" => true}) do |e|
      seen << :capture
      e.__js_call__("stopPropagation", [])
    end
    @btn.add_event_listener("click", nil, nil) { seen << :bubble }
    @outer.add_event_listener("click", nil, nil) { seen << :ancestor }
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal([:capture], seen)
  end

  def test_non_bubbling_event_still_runs_target_bubble_listener
    seen = []
    @btn.add_event_listener("click", nil, nil) { seen << :bubble }
    @outer.add_event_listener("click", nil, nil) { seen << :ancestor }
    @btn.dispatch_event(Dommy::Event.new("click"))
    assert_equal([:bubble], seen)
  end

  # ---- re-entrant dispatch ----

  def test_redispatching_an_in_flight_event_throws_invalid_state_error
    event = Dommy::Event.new("click")
    error = nil
    @btn.add_event_listener("click") do
      begin
        @btn.dispatch_event(event)
      rescue Dommy::DOMException => e
        error = e
      end
    end
    @btn.dispatch_event(event)
    assert_instance_of(Dommy::DOMException::InvalidStateError, error)
  end

  def test_event_can_be_dispatched_again_after_dispatch_completes
    event = Dommy::Event.new("click")
    count = 0
    @btn.add_event_listener("click") { count += 1 }
    @btn.dispatch_event(event)
    @btn.dispatch_event(event)
    assert_equal(2, count)
  end

  # ---- disabled form controls ----

  def test_click_on_disabled_button_dispatches_nothing
    @btn.set_attribute("disabled", "")
    fired = 0
    @btn.add_event_listener("click") { fired += 1 }
    @btn.click
    assert_equal(0, fired)
  end

  def test_click_on_control_inside_disabled_fieldset_dispatches_nothing
    @doc.body.inner_html = "<fieldset disabled><input id='i'></fieldset>"
    input = @doc.get_element_by_id("i")
    fired = 0
    input.add_event_listener("click") { fired += 1 }
    input.click
    assert_equal(0, fired)
  end

  def test_click_on_control_in_a_disabled_fieldsets_legend_still_dispatches
    @doc.body.inner_html = "<fieldset disabled><legend><input id='i'></legend></fieldset>"
    input = @doc.get_element_by_id("i")
    fired = 0
    input.add_event_listener("click") { fired += 1 }
    input.click
    assert_equal(1, fired)
  end

  def test_click_on_enabled_button_still_dispatches
    fired = 0
    @btn.add_event_listener("click") { fired += 1 }
    @btn.click
    assert_equal(1, fired)
  end

  def test_click_on_a_disabled_non_form_element_still_dispatches
    # `disabled` is meaningless on a div — only the disable-able form controls
    # are "actually disabled".
    div = @doc.create_element("div")
    div.set_attribute("disabled", "")
    fired = 0
    div.add_event_listener("click") { fired += 1 }
    div.click
    assert_equal(1, fired)
  end
end

class TestWPTInlineStyleImportant < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @el = @doc.create_element("div")
  end

  def test_set_property_with_important_priority
    @el.style.set_property("color", "red", "important")
    assert_equal("color: red !important;", @el.style.css_text)
    assert_equal("color: red !important;", @el.get_attribute("style"))
  end

  def test_get_property_value_excludes_the_important_flag
    @el.style.set_property("color", "red", "important")
    assert_equal("red", @el.style.get_property_value("color"))
  end

  def test_get_property_priority
    @el.style.set_property("color", "red", "important")
    @el.style.set_property("width", "1px")
    assert_equal("important", @el.style.get_property_priority("color"))
    assert_equal("", @el.style.get_property_priority("width"))
    assert_equal("", @el.style.get_property_priority("height"))
  end

  def test_important_round_trips_through_css_text
    @el.style.css_text = "color: red!important; background: blue"
    assert_equal("color: red !important; background: blue;", @el.style.css_text)
    assert_equal("important", @el.style.get_property_priority("color"))
    assert_equal("red", @el.style.get_property_value("color"))
  end

  def test_important_round_trips_from_the_style_attribute
    @el.set_attribute("style", "color: red ! important")
    assert_equal("important", @el.style.get_property_priority("color"))
    assert_equal("red", @el.style.get_property_value("color"))
  end

  def test_resetting_without_a_priority_clears_importance
    @el.style.set_property("color", "red", "important")
    @el.style.set_property("color", "blue")
    assert_equal("", @el.style.get_property_priority("color"))
    assert_equal("color: blue;", @el.style.css_text)
  end

  def test_camel_case_writer_clears_importance
    @el.style.set_property("color", "red", "important")
    @el.style.color = "blue"
    assert_equal("color: blue;", @el.style.css_text)
  end

  def test_indexing_and_length_ignore_the_priority
    @el.style.set_property("color", "red", "important")
    assert_equal("color", @el.style[0])
    assert_equal(1, @el.style.length)
    assert_equal("red", @el.style.color)
  end

  def test_remove_property_returns_the_value_without_the_flag
    @el.style.set_property("color", "red", "important")
    assert_equal("red", @el.style.remove_property("color"))
    assert_equal("", @el.style.css_text)
  end

  def test_js_bridge_set_and_read_priority
    style = @el.__js_get__("style")
    style.__js_call__("setProperty", ["color", "red", "important"])
    assert_equal("red", style.__js_call__("getPropertyValue", ["color"]))
    assert_equal("important", style.__js_call__("getPropertyPriority", ["color"]))
    assert_equal("color: red !important;", style.__js_get__("cssText"))
  end

  def test_js_bridge_absent_property_reads_as_empty_string
    style = @el.__js_get__("style")
    assert_equal("", style.__js_call__("getPropertyValue", ["nope"]))
    assert_equal("", style.__js_call__("getPropertyPriority", ["nope"]))
  end

  def test_invalid_declarations_are_still_dropped
    @el.style.css_text = "color:: bad; width: 1px"
    assert_equal("width: 1px;", @el.style.css_text)
  end
end
