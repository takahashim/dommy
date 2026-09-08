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

  # stopPropagation() at the target during the capturing pass. The target
  # appears TWICE in the event path traversal (once per pass), and "invoke"
  # returns early when the stop propagation flag is set — so the bubbling visit
  # to the same target never reaches its listeners. This reading of the dispatch
  # algorithm is what Chromium does too (cross-checked in a headless browser),
  # so it is not merely an artifact of how Dommy structures its two passes.
  #
  # Spec: https://dom.spec.whatwg.org/#concept-event-listener-invoke step 4
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

  # stopPropagation() stops LATER targets, not the remaining listeners on the
  # one currently being invoked — the second at-target capture listener still
  # runs. (Its sibling below is what stops those.)
  def test_stop_propagation_does_not_skip_sibling_listeners_on_the_same_target
    seen = []
    @btn.add_event_listener("click", nil, {"capture" => true}) do |e|
      seen << :capture1
      e.__js_call__("stopPropagation", [])
    end
    @btn.add_event_listener("click", nil, {"capture" => true}) { seen << :capture2 }
    @btn.add_event_listener("click", nil, nil) { seen << :bubble }
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal(%i[capture1 capture2], seen)
  end

  # stopImmediatePropagation() additionally drops the remaining listeners on the
  # current target, so only the first one runs.
  def test_stop_immediate_propagation_also_skips_sibling_listeners
    seen = []
    @btn.add_event_listener("click", nil, {"capture" => true}) do |e|
      seen << :capture1
      e.__js_call__("stopImmediatePropagation", [])
    end
    @btn.add_event_listener("click", nil, {"capture" => true}) { seen << :capture2 }
    @btn.add_event_listener("click", nil, nil) { seen << :bubble }
    @outer.add_event_listener("click", nil, nil) { seen << :ancestor }
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert_equal([:capture1], seen)
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

# CSSOM setProperty step 4: a priority that is neither the empty string nor an
# ASCII case-insensitive "important" abandons the call — the declaration block
# is left exactly as it was, rather than the flag being normalized away and the
# value written anyway.
#
# WPT: css/cssom/setproperty-null-undefined.html
# Spec: https://drafts.csswg.org/cssom/#dom-cssstyledeclaration-setproperty
class TestWPTSetPropertyPriorityValidation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @el = @doc.create_element("div")
  end

  def with_red_important
    @el.set_attribute("style", "color: red !important")
    yield @el.style
    @el.get_attribute("style")
  end

  def test_important_in_any_ascii_case_is_accepted
    assert_equal("color: blue !important;", with_red_important { |s| s.set_property("color", "blue", "important") })
    assert_equal("color: blue !important;", with_red_important { |s| s.set_property("color", "blue", "IMPORTANT") })
  end

  def test_the_empty_string_and_a_missing_priority_clear_importance
    assert_equal("color: blue;", with_red_important { |s| s.set_property("color", "blue", "") })
    assert_equal("color: blue;", with_red_important { |s| s.set_property("color", "blue", nil) })
    assert_equal("color: blue;", with_red_important { |s| s.set_property("color", "blue") })
  end

  # No trimming, no near-misses: each of these leaves the block untouched.
  def test_an_invalid_priority_is_a_no_op
    ["bogus", "important!", " important ", "!important"].each do |priority|
      assert_equal("color: red !important",
        with_red_important { |s| s.set_property("color", "blue", priority) },
        "priority #{priority.inspect} must not change the declaration block")
    end
  end

  def test_an_invalid_priority_queues_no_mutation_record
    @doc.body.append_child(@el)
    @el.set_attribute("style", "color: red !important")
    observer = Dommy::MutationObserver.new(@win, proc { |_recs| nil })
    observer.__js_call__("observe", [@el, {"attributes" => true}])
    @el.style.set_property("color", "blue", "bogus")
    assert_empty(observer.__js_call__("takeRecords", []))
  end

  # Step 3 (empty value removes the declaration) runs BEFORE step 4, so the
  # priority never gets a say. Chromium checks the priority first and keeps the
  # declaration here; Dommy follows the spec's order.
  def test_an_empty_value_removes_the_declaration_whatever_the_priority
    assert_equal("", with_red_important { |s| s.set_property("color", "", "bogus") })
  end

  def test_the_js_bridge_agrees_with_the_ruby_api
    @el.set_attribute("style", "color: red !important")
    style = @el.__js_get__("style")
    style.__js_call__("setProperty", ["color", "blue", "bogus"])
    assert_equal("red", style.__js_call__("getPropertyValue", ["color"]))
    assert_equal("important", style.__js_call__("getPropertyPriority", ["color"]))

    style.__js_call__("setProperty", ["color", "blue", "IMPORTANT"])
    assert_equal("blue", style.__js_call__("getPropertyValue", ["color"]))
  end

  # A stylesheet rule's declaration block is a CSSStyleDeclaration too, and has
  # to enforce the same rule.
  def test_a_rule_declaration_block_validates_the_priority_too
    document = Dommy.parse("<style>p { color: red !important }</style>").document
    style = document.query_selector("style").sheet.css_rules[0].style
    style.set_property("color", "blue", "bogus")
    assert_equal("red", style.get_property_value("color"))
    assert_equal("important", style.get_property_priority("color"))

    style.set_property("color", "blue", "Important")
    assert_equal("blue", style.get_property_value("color"))
    assert_equal("important", style.get_property_priority("color"))
  end
end
