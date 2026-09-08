# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the click activation behavior the dispatch algorithm
# runs, and for the legacy `window.event` global.
#
# WPT: dom/events/Event-dispatch-click.html,
#      dom/events/Event-dispatch-single-activation-behavior.html,
#      dom/events/Event-dispatch-detached-input-and-change.html,
#      dom/events/event-global.html
class TestWPTClickActivation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def checkbox(attach: true)
    input = @doc.create_element("input")
    input.type = "checkbox"
    @doc.body.append_child(input) if attach
    input
  end

  def click_event(bubbles: true)
    Dommy::MouseEvent.new("click", "bubbles" => bubbles, "cancelable" => true)
  end

  # The activation behavior belongs to dispatch, so a synthesized click is
  # indistinguishable from `click()`.
  def test_dispatching_a_mouse_event_click_toggles_a_checkbox
    input = checkbox
    input.dispatch_event(click_event)
    assert(input.checked)
  end

  def test_the_new_state_is_already_visible_inside_the_click_listener
    input = checkbox
    seen = nil
    input.add_event_listener("click") { seen = input.checked }
    input.dispatch_event(click_event)
    assert_equal(true, seen)
  end

  def test_a_plain_event_named_click_does_not_activate
    input = checkbox
    input.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    refute(input.checked)
  end

  def test_a_canceled_click_restores_the_previous_state
    input = checkbox
    input.add_event_listener("click") { |e| e.__js_call__("preventDefault", []) }
    input.click
    refute(input.checked)
  end

  def test_a_canceled_click_restores_indeterminate
    input = checkbox
    input.indeterminate = true
    input.add_event_listener("click") { |e| e.__js_call__("preventDefault", []) }
    input.click
    assert(input.indeterminate)
  end

  def test_an_attached_checkbox_fires_input_then_change
    input = checkbox
    seen = []
    input.add_event_listener("input") { seen << "input" }
    input.add_event_listener("change") { seen << "change" }
    input.click
    assert_equal(%w[input change], seen)
  end

  def test_input_and_change_also_fire_for_a_synthesized_click
    input = checkbox
    seen = []
    input.add_event_listener("input") { seen << "input" }
    input.add_event_listener("change") { seen << "change" }
    input.dispatch_event(click_event)
    assert_equal(%w[input change], seen)
  end

  # HTML's input activation behavior fires input/change only "if the element is
  # connected" — a detached checkbox still toggles, silently.
  def test_a_detached_checkbox_toggles_without_firing_input_or_change
    input = checkbox(attach: false)
    seen = []
    input.add_event_listener("input") { seen << "input" }
    input.add_event_listener("change") { seen << "change" }
    input.click
    assert(input.checked)
    assert_empty(seen)
  end

  def test_only_the_innermost_activation_target_runs
    outer = checkbox
    inner = checkbox(attach: false)
    outer.append_child(inner)
    inner.click
    assert(inner.checked)
    refute(outer.checked)
  end

  # The activation target is looked for beyond the target itself only when the
  # event bubbles.
  def test_a_non_bubbling_click_does_not_look_at_parents
    input = checkbox
    child = @doc.create_text_node("does not matter")
    input.append_child(child)
    child.dispatch_event(click_event(bubbles: false))
    refute(input.checked)
  end

  def test_a_bubbling_click_on_a_child_activates_the_ancestor
    input = checkbox
    child = @doc.create_text_node("does not matter")
    input.append_child(child)
    child.dispatch_event(click_event)
    assert(input.checked)
  end

  def test_a_radio_activates_and_unchecks_its_group
    form = @doc.create_element("form")
    form.inner_html = "<input type='radio' name='r' value='1' checked><input type='radio' name='r' value='2'>"
    @doc.body.append_child(form)
    first, second = form.elements.to_a
    second.dispatch_event(click_event)
    assert(second.checked)
    refute(first.checked)
  end

  def test_a_canceled_radio_click_restores_the_previously_checked_member
    form = @doc.create_element("form")
    form.inner_html = "<input type='radio' name='r' value='1' checked><input type='radio' name='r' value='2'>"
    @doc.body.append_child(form)
    first, second = form.elements.to_a
    second.add_event_listener("click") { |e| e.__js_call__("preventDefault", []) }
    second.click
    assert(first.checked)
    refute(second.checked)
  end

  def test_click_refuses_on_a_disabled_checkbox
    input = checkbox
    input.disabled = true
    input.click
    refute(input.checked)
  end

  # HTML's input activation behavior runs for Checkbox and Radio even when the
  # control is not mutable, so an explicitly dispatched click still toggles it —
  # only `click()` itself refuses.
  def test_an_explicit_click_on_a_disabled_checkbox_still_activates
    input = checkbox
    input.disabled = true
    input.dispatch_event(click_event)
    assert(input.checked)
  end

  def test_a_bubbling_click_on_a_child_of_an_anchor_navigates
    anchor = @doc.create_element("a")
    anchor.set_attribute("href", "#target")
    @doc.body.append_child(anchor)
    span = @doc.create_element("span")
    anchor.append_child(span)
    span.dispatch_event(click_event)
    assert_equal("#target", @win.location.__js_get__("hash"))
  end

  def test_a_non_bubbling_click_on_that_child_does_not_navigate
    anchor = @doc.create_element("a")
    anchor.set_attribute("href", "#nope")
    @doc.body.append_child(anchor)
    span = @doc.create_element("span")
    anchor.append_child(span)
    span.dispatch_event(click_event(bubbles: false))
    assert_equal("", @win.location.__js_get__("hash"))
  end
end

class TestWPTWindowEventGlobal < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @node = @doc.create_element("div")
    @doc.body.append_child(@node)
  end

  def undefined?(value)
    value.equal?(Dommy::Bridge::UNDEFINED)
  end

  def test_window_event_is_undefined_outside_a_dispatch
    assert(undefined?(@win.__js_get__("event")))
  end

  def test_window_event_is_the_event_during_a_dispatch
    event = Dommy::Event.new("test", "bubbles" => true)
    seen = nil
    @node.add_event_listener("test") { seen = @win.__js_get__("event") }
    @node.dispatch_event(event)
    assert_same(event, seen)
  end

  def test_window_event_is_undefined_again_after_the_dispatch
    @node.add_event_listener("test") { nil }
    @node.dispatch_event(Dommy::Event.new("test", "bubbles" => true))
    assert(undefined?(@win.__js_get__("event")))
  end

  def test_window_event_is_undefined_for_a_listener_inside_a_shadow_tree
    host = @doc.create_element("x-host")
    @doc.body.append_child(host)
    root = host.attach_shadow(mode: "open")
    root.inner_html = "<i id='in'></i>"
    inner = root.query_selector("#in")

    inside = :unset
    outside = :unset
    inner.add_event_listener("test") { inside = @win.__js_get__("event") }
    @doc.body.add_event_listener("test") { outside = @win.__js_get__("event") }
    event = Dommy::Event.new("test", "bubbles" => true, "composed" => true)
    inner.dispatch_event(event)

    assert(undefined?(inside), "a shadow-tree listener must not see window.event")
    assert_same(event, outside)
  end

  def test_a_nested_dispatch_restores_the_outer_event
    inner_event = Dommy::Event.new("inner")
    outer_event = Dommy::Event.new("outer")
    after_nested = nil
    @node.add_event_listener("inner") { nil }
    @node.add_event_listener("outer") do
      @node.dispatch_event(inner_event)
      after_nested = @win.__js_get__("event")
    end
    @node.dispatch_event(outer_event)
    assert_same(outer_event, after_nested)
  end
end

# WPT: html/semantics/forms/resetting-a-form/{reset-form,reset-form-2,reset-event}.html
class TestWPTFormReset < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def dirty_form(attach: true)
    form = @doc.create_element("form")
    form.inner_html = <<~HTML
      <input name="t" value="default text">
      <textarea name="ta">default area</textarea>
      <select name="s"><option value="1">1</option><option value="2" selected>2</option></select>
      <input type="checkbox" name="c" checked>
      <input type="reset">
    HTML
    @doc.body.append_child(form) if attach
    text, area, select, box, = form.elements.to_a
    text.value = "typed"
    area.value = "typed"
    select.value = "1"
    box.checked = false
    form
  end

  def test_reset_restores_every_control
    form = dirty_form
    text, area, select, box, = form.elements.to_a
    form.reset
    assert_equal("default text", text.value)
    assert_equal("default area", area.value)
    assert_equal("2", select.value)
    assert(box.checked)
  end

  def test_a_reset_button_click_resets_the_form
    form = dirty_form
    text = form.elements.to_a.first
    form.elements.to_a.last.click
    assert_equal("default text", text.value)
  end

  def test_a_canceled_reset_event_leaves_the_controls_alone
    form = dirty_form
    text = form.elements.to_a.first
    form.add_event_listener("reset") { |e| e.__js_call__("preventDefault", []) }
    refute(form.reset)
    assert_equal("typed", text.value)
  end

  def test_the_reset_event_is_trusted_and_cancelable
    form = @doc.create_element("form")
    seen = nil
    form.add_event_listener("reset") { |e| seen = e }
    form.reset
    assert(seen.__js_get__("bubbles"))
    assert(seen.__js_get__("cancelable"))
    assert(seen.__js_get__("isTrusted"))
    assert_same(form, seen.__js_get__("target"))
  end

  # A form built in script and never inserted still owns the controls in its own
  # subtree, so resetting it works.
  def test_a_detached_form_resets_its_own_controls
    form = dirty_form(attach: false)
    text = form.elements.to_a.first
    assert_equal("typed", text.value)
    form.reset
    assert_equal("default text", text.value)
  end

  # A single-selection select always ends up with one option selected, so a
  # reset that clears every `selected` attribute falls back to the first option.
  def test_reset_selects_the_first_option_when_none_is_marked_selected
    form = @doc.create_element("form")
    form.inner_html = "<select><option value='1'>1</option><option value='2'>2</option></select>"
    @doc.body.append_child(form)
    select = form.elements.to_a.first
    select.value = "2"
    form.reset
    assert(select.options[0].selected)
    assert_equal("1", select.value)
  end

  def test_a_button_type_reset_also_resets
    form = @doc.create_element("form")
    form.inner_html = "<input name='t' value='d'><button type='reset'></button>"
    @doc.body.append_child(form)
    text, button = form.elements.to_a
    text.value = "typed"
    button.click
    assert_equal("d", text.value)
  end
end

# WPT: html/semantics/interactive-elements/the-details-element — a summary's
# activation behavior toggles its details.
class TestWPTSummaryActivation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @host.inner_html = "<details><summary id='s'>t</summary><p>body</p></details>"
    @doc.body.append_child(@host)
    @details = @host.query_selector("details")
    @summary = @host.query_selector("#s")
  end

  def test_clicking_the_summary_toggles_the_details
    refute(@details.open)
    @summary.click
    assert(@details.open)
    @summary.click
    refute(@details.open)
  end

  def test_a_canceled_click_leaves_the_details_shut
    @summary.add_event_listener("click") { |e| e.__js_call__("preventDefault", []) }
    @summary.click
    refute(@details.open)
  end

  def test_only_the_first_summary_toggles
    @host.inner_html = "<details><summary id='a'>a</summary><summary id='b'>b</summary></details>"
    details = @host.query_selector("details")
    @host.query_selector("#b").click
    refute(details.open)
    @host.query_selector("#a").click
    assert(details.open)
  end
end
