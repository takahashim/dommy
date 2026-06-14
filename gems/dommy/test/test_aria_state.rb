# frozen_string_literal: true

require_relative "test_helper"

# Internal::AriaState.compute(element, role) — the ARIA state set the
# accessibility tree exposes (native state wins, else aria-* attributes).
class TestAriaState < Minitest::Test
  include DommyTestHelper

  def state_of(html, selector)
    el = make_window(html).document.query_selector(selector)
    Dommy::Internal::AriaState.compute(el, el.computed_role)
  end

  def test_checkbox_checked_and_unchecked
    assert_equal({checked: true}, state_of('<input type="checkbox" checked>', "input"))
    assert_equal({checked: false}, state_of('<input type="checkbox">', "input"))
  end

  def test_checkbox_indeterminate_is_mixed
    win = make_window('<input type="checkbox">')
    el = win.document.query_selector("input")
    el.indeterminate = true
    assert_equal({checked: "mixed"}, Dommy::Internal::AriaState.compute(el, el.computed_role))
  end

  def test_aria_checked_tristate_on_non_native
    assert_equal({checked: "mixed"}, state_of('<div role="checkbox" aria-checked="mixed"></div>', "div"))
    assert_equal({checked: true}, state_of('<div role="checkbox" aria-checked="true"></div>', "div"))
  end

  def test_button_pressed
    assert_equal({pressed: true}, state_of('<button aria-pressed="true">x</button>', "button"))
  end

  def test_option_selected
    html = "<select><option selected>A</option><option>B</option></select>"
    assert_equal({selected: true}, state_of(html, "option")) # first option
  end

  def test_expanded_from_aria_expanded_only
    # A native <details open> (role group) carries no expanded state; only
    # aria-expanded does.
    assert_equal({}, state_of("<details open><summary>s</summary></details>", "details"))
    assert_equal({expanded: true}, state_of('<div role="button" aria-expanded="true">x</div>', "div"))
    assert_equal({expanded: false}, state_of('<div role="button" aria-expanded="false">x</div>', "div"))
  end

  def test_disabled_native_and_aria
    assert_equal(true, state_of('<input type="text" disabled>', "input")[:disabled])
    assert_equal(true, state_of('<div role="textbox" aria-disabled="true"></div>', "div")[:disabled])
    # <button>/<select>/<textarea> carry the disabled attribute but no reflected
    # IDL property — read it off the attribute.
    assert_equal(true, state_of("<button disabled>x</button>", "button")[:disabled])
  end

  def test_required_and_readonly
    assert_equal(true, state_of('<input type="text" required>', "input")[:required])
    assert_equal(true, state_of('<input type="text" readonly>', "input")[:readonly])
  end

  def test_heading_level_and_aria_level
    assert_equal({level: 2}, state_of("<h2>x</h2>", "h2"))
    assert_equal({level: 5}, state_of('<div role="heading" aria-level="5">x</div>', "div"))
  end

  def test_level_only_for_level_supporting_roles
    refute_includes state_of("<p>x</p>", "p").keys, :level
    # An hN keeps its level under listitem/row/treeitem, but not under a role
    # that does not support aria-level (tablist).
    assert_equal 2, state_of('<h2 role="listitem">x</h2>', "h2")[:level]
    refute_includes state_of('<h2 role="tablist">x</h2>', "h2").keys, :level
  end

  def test_plain_element_has_empty_state
    assert_equal({}, state_of("<p>hi</p>", "p"))
  end
end
