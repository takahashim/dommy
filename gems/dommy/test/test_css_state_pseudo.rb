# frozen_string_literal: true

require_relative "test_helper"

# State pseudo-classes (:hover / :focus / :focus-within / :checked) evaluated
# against DOM state, shared between querySelector*/matches and the CSS
# cascade (css-cascade.md P4).
class TestCssStatePseudo < Minitest::Test
  CASCADE = Dommy::Internal::CSS::Cascade

  def doc_for(html)
    Dommy.parse(html).document
  end

  # --- :hover ---------------------------------------------------------

  def test_hover_matches_the_hovered_element_and_its_ancestors
    doc = doc_for('<div id="outer"><button id="b">x</button></div><p id="other">y</p>')
    button = doc.get_element_by_id("b")

    refute button.matches?(":hover")

    doc.__set_hovered_element__(button)
    assert button.matches?(":hover")
    assert doc.get_element_by_id("outer").matches?(":hover")
    refute doc.get_element_by_id("other").matches?(":hover")

    doc.__set_hovered_element__(nil)
    refute button.matches?(":hover")
  end

  def test_hover_in_query_selector_all
    doc = doc_for('<button id="a">a</button><button id="b">b</button>')
    doc.__set_hovered_element__(doc.get_element_by_id("b"))

    assert_equal ["b"], doc.query_selector_all("button:hover").map { |el| el.get_attribute("id") }
  end

  def test_hover_rule_reflects_in_computed_style
    doc = doc_for(<<~HTML)
      <style>
        #menu { display: none }
        #item:hover #menu { display: block }
      </style>
      <div id="item"><div id="menu">m</div></div>
    HTML
    menu = doc.get_element_by_id("menu")
    assert_equal "none", CASCADE.computed_style(menu)["display"]

    doc.__set_hovered_element__(menu)
    assert_equal "block", CASCADE.computed_style(menu)["display"]

    doc.__set_hovered_element__(nil)
    assert_equal "none", CASCADE.computed_style(menu)["display"]
  end

  # --- :focus / :focus-within ------------------------------------------

  def test_focus_matches_only_the_explicitly_focused_element
    doc = doc_for('<form id="f"><input id="i"></form>')
    input = doc.get_element_by_id("i")

    # activeElement falls back to <body>, but nothing matches :focus yet.
    refute doc.body.matches?(":focus")
    refute input.matches?(":focus")

    input.focus
    assert input.matches?(":focus")
    assert input.matches?(":focus-visible")
    refute doc.get_element_by_id("f").matches?(":focus")
    assert doc.get_element_by_id("f").matches?(":focus-within")

    input.blur
    refute input.matches?(":focus")
    refute doc.get_element_by_id("f").matches?(":focus-within")
  end

  def test_focus_rule_reflects_in_computed_style
    doc = doc_for(<<~HTML)
      <style>#i:focus { background-color: yellow }</style>
      <input id="i">
    HTML
    input = doc.get_element_by_id("i")
    assert_equal "rgba(0, 0, 0, 0)", CASCADE.computed_style(input)["background-color"]

    input.focus
    assert_equal "rgb(255, 255, 0)", CASCADE.computed_style(input)["background-color"]
  end

  # --- :checked ---------------------------------------------------------

  def test_checked_follows_checkedness_not_the_attribute
    doc = doc_for('<input id="c" type="checkbox"><input id="r" type="radio" checked>')
    checkbox = doc.get_element_by_id("c")

    refute checkbox.matches?(":checked")
    # The radio's attribute provides the default checkedness.
    assert doc.get_element_by_id("r").matches?(":checked")

    checkbox.checked = true
    assert checkbox.matches?(":checked")
    assert_equal ["c", "r"], doc.query_selector_all("input:checked").map { |el| el.get_attribute("id") }

    checkbox.checked = false
    refute checkbox.matches?(":checked")
  end

  def test_checked_does_not_match_text_inputs_or_buttons
    doc = doc_for('<input id="t" type="text" checked><button id="b">x</button>')
    refute doc.get_element_by_id("t").matches?(":checked")
    refute doc.get_element_by_id("b").matches?(":checked")
  end

  def test_checked_matches_selected_options
    doc = doc_for('<select><option id="a">a</option><option id="b" selected>b</option></select>')
    refute doc.get_element_by_id("a").matches?(":checked")
    assert doc.get_element_by_id("b").matches?(":checked")
  end

  def test_checked_rule_reflects_in_computed_style_via_property
    doc = doc_for(<<~HTML)
      <style>#c:checked { opacity: 0.5 }</style>
      <input id="c" type="checkbox">
    HTML
    checkbox = doc.get_element_by_id("c")
    assert_equal "1", CASCADE.computed_style(checkbox)["opacity"]

    checkbox.checked = true
    assert_equal "0.5", CASCADE.computed_style(checkbox)["opacity"]
  end

  # --- :active stays inert ----------------------------------------------

  def test_active_still_matches_nothing
    doc = doc_for('<button id="b">x</button>')
    refute doc.get_element_by_id("b").matches?(":active")
    assert_empty doc.query_selector_all("button:active").to_a
  end
end
