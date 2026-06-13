# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for the CSSOM stylesheet/rule object model:
# insertRule/deleteRule, cssRules, and the typed rule accessors (selectorText,
# style, conditionText, cssRules of @media). Adapted (not mirrored) from the
# cssom idlharness / CSSStyleSheet test pages.
#
# WPT: css/cssom/CSSStyleSheet.html, css/cssom/insertRule-*.html,
#      css/cssom/CSSMediaRule.html, css/cssom/cssstyledeclaration-*
# Spec: https://drafts.csswg.org/cssom/#the-cssstylesheet-interface
class TestWPTCssomStylesheet < Minitest::Test
  def sheet(css = "")
    document = Dommy.parse("<style>#{css}</style>").document
    document.query_selector("style").sheet
  end

  def test_style_rule_splits_and_exposes_selector_and_style
    s = sheet("p, a.x { color: red; font-size: 12px } div { color: blue }")
    assert_equal 2, s.css_rules.length
    rule = s.css_rules[0]
    assert_equal Dommy::CSSRule::STYLE_RULE, rule.type
    assert_equal "p, a.x", rule.selector_text
    assert_equal "red", rule.style.get_property_value("color")
    assert_equal "12px", rule.style.get_property_value("font-size")
  end

  def test_insert_and_delete_rule_indices
    s = sheet
    assert_equal 0, s.insert_rule("p {}", 0)
    assert_equal 1, s.insert_rule("a {}")     # append
    assert_equal 0, s.insert_rule("b {}", 0)  # prepend
    assert_equal %w[b p a], s.css_rules.map(&:selector_text)
    s.delete_rule(1)
    assert_equal %w[b a], s.css_rules.map(&:selector_text)
  end

  def test_insert_rule_out_of_range_raises
    assert_raises(Dommy::DOMException::IndexSizeError) { sheet.insert_rule("p {}", 5) }
  end

  def test_delete_rule_out_of_range_raises
    assert_raises(Dommy::DOMException::IndexSizeError) { sheet.delete_rule(0) }
  end

  def test_priority_is_exposed
    rule = sheet("p { color: red !important }").css_rules[0]
    assert_equal "important", rule.style.get_property_priority("color")
  end

  def test_media_rule_type_condition_and_nested_rules
    rule = sheet("@media (min-width: 600px) { p { color: green } }").css_rules[0]
    assert_equal Dommy::CSSRule::MEDIA_RULE, rule.type
    assert_equal "(min-width: 600px)", rule.condition_text
    assert_equal 1, rule.css_rules.length
    assert_equal "green", rule.css_rules[0].style.get_property_value("color")
  end

  def test_css_text_round_trips_until_mutated
    rule = sheet("p { color: red }").css_rules[0]
    assert_equal "p { color: red }", rule.css_text
    rule.style.set_property("color", "green")
    assert_includes rule.css_text, "green"
  end

  def test_setProperty_invalidates_computed_style
    document = Dommy.parse('<style>#t { color: red }</style><p id="t">x</p>').document
    view = document.default_view
    target = document.get_element_by_id("t")
    assert_equal "rgb(255, 0, 0)", view.get_computed_style(target)["color"]

    document.query_selector("style").sheet.css_rules[0].style.set_property("color", "green")
    assert_equal "rgb(0, 128, 0)", view.get_computed_style(target)["color"]
  end
end
