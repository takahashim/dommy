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

  def test_hover_inside_not_keeps_negated_semantics
    doc = doc_for('<div id="a"></div><div id="b"></div>')
    doc.__set_hovered_element__(doc.get_element_by_id("b"))

    assert_equal ["a"], doc.query_selector_all("div:not(:hover)").map { |el| el.get_attribute("id") }
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

  def test_checked_on_non_subject_combinator_matches_subject
    doc = doc_for('<input id="c" type="checkbox"><label id="l" for="c">c</label>')
    checkbox = doc.get_element_by_id("c")

    assert_empty doc.query_selector_all("input:checked + label").to_a

    checkbox.checked = true
    assert_equal ["l"], doc.query_selector_all("input:checked + label").map { |el| el.get_attribute("id") }
    assert doc.get_element_by_id("l").matches?("input:checked + label")
  end

  def test_checked_inside_is_keeps_other_branches
    doc = doc_for('<input id="c" type="checkbox"><div id="x" class="x"></div>')

    assert_equal ["x"], doc.query_selector_all(":is(:checked, .x)").map { |el| el.get_attribute("id") }

    doc.get_element_by_id("c").checked = true
    assert_equal ["c", "x"], doc.query_selector_all(":is(:checked, .x)").map { |el| el.get_attribute("id") }
  end

  def test_has_relative_selector_observes_checkedness
    doc = doc_for('<label id="l">c</label><input id="c" type="checkbox">')

    assert_empty doc.query_selector_all("label:has(+ input:checked)").to_a

    doc.get_element_by_id("c").checked = true
    assert_equal ["l"], doc.query_selector_all("label:has(+ input:checked)").map { |el| el.get_attribute("id") }
  end

  def test_state_pseudo_matching_does_not_write_marker_attributes
    doc = doc_for('<input id="c" type="checkbox"><label id="l" for="c">c</label>')
    doc.get_element_by_id("c").checked = true

    doc.query_selector_all("input:checked + label")

    doc.query_selector_all("*").each do |element|
      refute element.get_attribute_names.any? { |name| name.start_with?("data-dommy-state-") }
    end
  end

  def test_not_has_and_nth_child_of_selector
    doc = doc_for('<section id="a"><p class="x">a</p></section><section id="b"></section><ul><li></li><li class="x" id="n"></li><li class="x"></li></ul>')

    assert_equal ["b"], doc.query_selector_all("section:not(:has(p.x))").map { |el| el.get_attribute("id") }
    assert_equal ["n"], doc.query_selector_all("li:nth-child(1 of .x)").map { |el| el.get_attribute("id") }
  end

  def test_selector_identifier_escapes_match_decoded_values
    doc = doc_for('<div id="#foo:bar" class="foo:bar test.foo[5]bar"></div><div id="1escape.me" data-random="abc\def"></div>')
    div = doc.query_selector("#\\#foo\\:bar")

    assert_equal "#foo:bar", div.get_attribute("id")
    assert_equal div, doc.query_selector(".foo\\:bar")
    assert_equal div, doc.query_selector(".test\\.foo\\[5\\]bar")
    assert_equal "1escape.me", doc.query_selector("#\\31 escape\\.me").get_attribute("id")
    assert_equal "1escape.me", doc.query_selector('div[data-random="abc\\\\def"]').get_attribute("id")
  end

  def test_disabled_fieldset_does_not_disable_first_legend_descendants
    doc = doc_for(<<~HTML)
      <fieldset disabled>
        <legend><input id="legend-input"></legend>
        <input id="fieldset-input">
      </fieldset>
    HTML

    refute doc.get_element_by_id("legend-input").matches?(":disabled")
    assert doc.get_element_by_id("fieldset-input").matches?(":disabled")
    assert_equal ["fieldset-input"], doc.query_selector_all("input:disabled").map { |el| el.get_attribute("id") }
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

  def test_checked_combinator_rule_reflects_in_computed_style
    doc = doc_for(<<~HTML)
      <style>input:checked + label { color: red }</style>
      <input id="c" type="checkbox"><label id="l" for="c">c</label>
    HTML
    label = doc.get_element_by_id("l")
    assert_equal "rgb(0, 0, 0)", CASCADE.computed_style(label)["color"]

    doc.get_element_by_id("c").checked = true
    assert_equal "rgb(255, 0, 0)", CASCADE.computed_style(label)["color"]
  end

  def test_is_branch_rule_reflects_in_computed_style
    doc = doc_for(<<~HTML)
      <style>:is(:checked, .x) { opacity: 0.25 }</style>
      <input id="c" type="checkbox"><div id="x" class="x"></div>
    HTML
    assert_equal "0.25", CASCADE.computed_style(doc.get_element_by_id("x"))["opacity"]
    assert_equal "1", CASCADE.computed_style(doc.get_element_by_id("c"))["opacity"]

    doc.get_element_by_id("c").checked = true
    assert_equal "0.25", CASCADE.computed_style(doc.get_element_by_id("c"))["opacity"]
  end

  # --- :active stays inert ----------------------------------------------

  def test_active_still_matches_nothing
    doc = doc_for('<button id="b">x</button>')
    refute doc.get_element_by_id("b").matches?(":active")
    assert_empty doc.query_selector_all("button:active").to_a
  end
end
