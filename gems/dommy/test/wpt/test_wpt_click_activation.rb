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

# WPT: dom/events/Event-dispatch-single-activation-behavior.html — the parts
# that pin <area> hyperlink activation, label forwarding, and the legacy
# nested-form dispatch rule.
class TestWPTAreaActivation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def area(href)
    el = @doc.create_element("area")
    el.href = href
    @doc.body.append_child(el)
    el
  end

  # `area.href` is a URL-decomposition IDL attribute, like the anchor's: the
  # setter writes the attribute verbatim, the getter resolves it.
  def test_area_href_reads_back_resolved
    el = area("#target")
    assert_equal("#target", el.get_attribute("href"))
    assert_equal("http://localhost/#target", el.href)
  end

  def test_area_exposes_the_url_decomposition_members
    el = area("http://example.com:8080/p?q=1#f")
    assert_equal("http:", el.protocol)
    assert_equal("example.com:8080", el.host)
    assert_equal("example.com", el.hostname)
    assert_equal("8080", el.port)
    assert_equal("/p", el.pathname)
    assert_equal("?q=1", el.search)
    assert_equal("#f", el.hash)
  end

  def test_clicking_an_area_navigates
    area("#area-target").click
    assert_equal("#area-target", @win.location.__js_get__("hash"))
  end
end

class TestWPTLabelActivation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def labeled(wrapper_html = nil)
    host = @doc.create_element("div")
    label = "<label><input type='checkbox'><span id='s'>t</span></label>"
    host.inner_html = wrapper_html ? wrapper_html.sub("%s", label) : label
    @doc.body.append_child(host)
    [host.query_selector("input"), host.query_selector("#s")]
  end

  def test_clicking_a_labels_text_activates_its_control
    box, span = labeled
    span.click
    assert(box.checked)
  end

  # The "do nothing" rule covers interactive content *inside* the label; the
  # control itself is one, so its own click is not forwarded a second time.
  def test_clicking_the_control_itself_toggles_only_once
    box, = labeled
    box.click
    assert(box.checked)
  end

  # Interactive content the label is nested *in* is not a descendant, so it must
  # not suppress the forwarding.
  def test_a_label_inside_a_link_still_forwards_the_click
    box, span = labeled("<a href='#l'>%s</a>")
    span.click
    assert(box.checked)
  end

  def test_a_label_inside_a_button_still_forwards_the_click
    box, span = labeled("<button type='button'>%s</button>")
    span.click
    assert(box.checked)
  end

  # Every kind of interactive content inside the label — not only form controls
  # and links — handles its own click (WPT the-label-element/
  # clicking-interactive-content): a click on it, or on something inside it, is
  # not forwarded to the label's control. A nested label counts too.
  def test_other_interactive_content_inside_the_label_is_left_alone
    %w[<details></details> <video\ controls></video> <audio\ controls></audio> <iframe></iframe>
       <embed> <img\ usemap='#m'> <label>inner</label>].each do |markup|
      host = @doc.create_element("div")
      host.inner_html = "<label><input type='checkbox'>#{markup.tr('\\', '')}</label>"
      @doc.body.append_child(host)
      box = host.query_selector("input")
      other = host.query_selector("label").last_element_child

      other.click
      refute(box.checked, "a click on #{markup} must not activate the control")
      inner = @doc.create_element("span")
      other.append_child(inner)
      inner.click
      refute(box.checked, "a click inside #{markup} must not activate the control")
    end
  end

  # Being interactive content itself must not make the label ignore a click on
  # its own text: only a nested interactive element counts.
  def test_the_label_itself_does_not_count_as_nested_interactive_content
    box, span = labeled
    span.click
    assert(box.checked)
  end

  # A video or audio WITHOUT controls, and an img without usemap, are not
  # interactive content: a click on them forwards like any other content.
  def test_media_without_controls_still_forwards_the_click
    host = @doc.create_element("div")
    host.inner_html = "<label><input type='checkbox'><video id='v'></video><img id='i'></label>"
    @doc.body.append_child(host)
    box = host.query_selector("input")
    host.query_selector("#v").click
    assert(box.checked)
    box.checked = false
    host.query_selector("#i").click
    assert(box.checked)
  end
end

# HTML's legacy nested-form dispatch rule: a form stops a `submit`/`reset` event
# that was fired at another node instead of running its own listeners, so an
# inner form's submission never activates the form it is nested in.
class TestWPTNestedFormEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.inner_html = <<~HTML
      <form id="outer"><span id="host"></span></form>
    HTML
    @outer = @doc.get_element_by_id("outer")
    @seen = []
    @outer.add_event_listener("submit") { @seen << "outer-submit" }
    @outer.add_event_listener("reset") { @seen << "outer-reset" }
  end

  def nest(inner_html)
    host = @doc.get_element_by_id("host")
    host.inner_html = "<form id='inner'>#{inner_html}</form>"
    inner = @doc.get_element_by_id("inner")
    inner.add_event_listener("submit") { |e| @seen << "inner-submit"; e.__js_call__("preventDefault", []) }
    inner.add_event_listener("reset") { @seen << "inner-reset" }
    inner
  end

  def test_an_inner_forms_submission_does_not_reach_the_outer_form
    inner = nest("<input type='submit'>")
    inner.query_selector("input").click
    assert_equal(["inner-submit"], @seen)
  end

  def test_an_inner_forms_reset_does_not_reach_the_outer_form
    inner = nest("<input type='reset'>")
    inner.query_selector("input").click
    assert_equal(["inner-reset"], @seen)
  end

  # The rule keys off the event's target, not off form nesting: a submit event
  # fired at any other node stops at the form too.
  def test_a_submit_fired_at_a_descendant_does_not_reach_the_form
    @doc.get_element_by_id("host").dispatch_event(Dommy::Event.new("submit", "bubbles" => true))
    assert_empty(@seen)
  end

  def test_a_submit_fired_at_the_form_itself_still_runs_its_listeners
    @outer.dispatch_event(Dommy::Event.new("submit", "bubbles" => true))
    assert_equal(["outer-submit"], @seen)
  end

  # Only the bubbling side is suppressed — the event still travels down to its
  # target, so a capturing listener on the outer form sees it.
  def test_a_capturing_listener_on_the_outer_form_still_sees_it
    captured = []
    @outer.add_event_listener("submit", ->(_e) { captured << "capture" }, true)
    inner = nest("<input type='submit'>")
    inner.query_selector("input").click
    assert_equal(["capture"], captured)
  end
end
