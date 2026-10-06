# frozen_string_literal: true

require_relative "test_helper"

# HTML's focus model (§6.6): what is focusable, focus() and blur(), focus
# delegation through shadow hosts, activeElement retargeting, the focus fixup,
# and autofocus.
class TestFocusModel < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <button id="b">b</button>
      <input id="i"><input id="hidden" type="hidden">
      <a id="link" href="#">l</a><a id="nolink">n</a>
      <div id="plain">p</div><div id="tab" tabindex="-1">t</div>
      <div id="edit" contenteditable>e</div>
      <button id="dis" disabled>d</button>
      <fieldset disabled><input id="infs"></fieldset>
      <div inert><button id="inert">x</button></div>
      <div style="display:none"><button id="none">x</button></div>
      <details id="det"><summary id="sum">s</summary><button id="closed">x</button></details>
      <div id="host"></div>
    HTML
    @doc = @win.document
    @events = []
  end

  def el(id) = @doc.get_element_by_id(id)

  def focusable?(id) = Dommy::Internal::Focusability.focusable_area?(el(id))

  def test_focusable_areas
    %w[b i link tab edit sum].each { |id| assert focusable?(id), id }
    %w[hidden nolink plain dis infs inert none closed].each { |id| refute focusable?(id), id }
  end

  def test_focus_on_a_non_focusable_element_is_a_no_op
    el("b").focus
    el("plain").focus
    assert_same el("b"), @doc.active_element
  end

  def test_focus_on_a_disconnected_element_is_a_no_op
    button = @doc.create_element("button")
    button.focus
    assert_same @doc.body, @doc.active_element
  end

  def test_focus_events_are_trusted_with_a_view_and_related_targets
    record = ->(e) { [e.type, e.related_target.id, e.__js_get__("isTrusted"), e.__js_get__("view").equal?(@win)] }
    el("i").add_event_listener("blur", proc { |e| @events << record.(e) })
    el("b").add_event_listener("focus", proc { |e| @events << record.(e) })
    el("i").focus
    el("b").focus
    assert_equal [["blur", "b", true, true], ["focus", "i", true, true]], @events
  end

  def test_focusing_the_document_element_focuses_the_viewport
    el("b").focus
    @doc.document_element.focus
    assert_same @doc.body, @doc.active_element
    assert_nil @doc.__internal_focused_element__
  end

  def test_delegates_focus_hands_focus_to_the_first_focusable_descendant
    root = el("host").attach_shadow("mode" => "open", "delegatesFocus" => true)
    root.inner_html = "<span>x</span><input id='inner'>"
    inner = root.query_selector("#inner")
    el("host").focus
    assert_same inner, root.active_element
    # document.activeElement is the focused element retargeted: the host.
    assert_same el("host"), @doc.active_element
    assert el("host").matches?(":focus")
    assert el("host").matches?(":focus-within")
  end

  def test_shadow_root_active_element_for_nested_trees
    outer = el("host").attach_shadow("mode" => "open")
    outer.inner_html = "<div id='inner-host'></div>"
    inner_host = outer.query_selector("#inner-host")
    inner = inner_host.attach_shadow("mode" => "open")
    inner.inner_html = "<button id='deep'>x</button>"
    inner.query_selector("#deep").focus
    assert_same inner_host, outer.active_element
    assert_same inner.query_selector("#deep"), inner.active_element
    assert_same el("host"), @doc.active_element
  end

  def test_removing_the_focused_element_resets_focus_without_blur
    el("i").add_event_listener("blur", proc { @events << :blur })
    el("i").focus
    el("i").remove
    assert_same @doc.body, @doc.active_element
    assert_empty @events
  end

  def test_removing_an_ancestor_of_the_focused_element_resets_focus
    root = el("host").attach_shadow("mode" => "open")
    root.inner_html = "<button>x</button>"
    root.query_selector("button").focus
    el("host").remove
    assert_nil @doc.__internal_focused_element__
  end

  def test_the_focus_fixup_blurs_an_element_that_stops_being_focusable
    el("b").add_event_listener("blur", proc { @events << :blur })
    el("b").focus
    el("b").set_attribute("disabled", "")
    assert_same el("b"), @doc.active_element
    @win.scheduler.advance_time(20)
    assert_equal [:blur], @events
    assert_same @doc.body, @doc.active_element
  end

  def test_autofocus_focuses_the_first_candidate_at_the_next_rendering_update
    win = make_window("<input id='a' autofocus><input id='b' autofocus>")
    assert_same win.document.body, win.document.active_element
    win.scheduler.advance_time(20)
    assert_same win.document.get_element_by_id("a"), win.document.active_element
  end

  def test_autofocus_skips_non_focusable_candidates
    win = make_window("<div autofocus>x</div><input id='b' autofocus>")
    win.scheduler.advance_time(20)
    assert_same win.document.get_element_by_id("b"), win.document.active_element
  end

  def test_autofocus_is_not_processed_when_something_is_already_focused
    win = make_window("<button id='x'>x</button><input id='a' autofocus>")
    win.document.get_element_by_id("x").focus
    win.scheduler.advance_time(20)
    assert_same win.document.get_element_by_id("x"), win.document.active_element
  end
end
