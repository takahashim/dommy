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

  def test_css_text_is_reserialized_from_the_declarations
    rule = sheet("p { color: red }").css_rules[0]
    assert_equal "p { color: red; }", rule.css_text
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

# CSSOM gives every rule kind its own interface, and dommy backs them all with
# one Ruby class carrying a `type` — so which interface a rule reports has to be
# derived per instance rather than per class.
# WPT: css/cssom/CSSStyleSheet.html
class TestWPTCssRuleInterfaces < Minitest::Test
  include DommyTestHelper

  def rules(css)
    win = make_window
    style = win.document.create_element("style")
    style.text_content = css
    win.document.body.append_child(style)
    style.sheet.css_rules
  end

  def chain(rule)
    Dommy::Js::DomInterfaces.chain_for(rule)
  end

  def test_a_style_rule_reports_CSSStyleRule
    assert_equal(%w[CSSStyleRule CSSGroupingRule CSSRule], chain(rules("p { color: red }").item(0)))
  end

  def test_a_media_rule_reports_CSSMediaRule
    rule = rules("@media all { p { color: red } }").item(0)
    assert_equal(%w[CSSMediaRule CSSConditionRule CSSGroupingRule CSSRule], chain(rule))
  end

  def test_a_supports_rule_reports_CSSSupportsRule
    rule = rules("@supports (color: red) { p { color: red } }").item(0)
    assert_equal(%w[CSSSupportsRule CSSConditionRule CSSGroupingRule CSSRule], chain(rule))
  end

  # The interface depends on the instance, so nothing may memoize it per class.
  def test_the_interface_is_not_memoized_per_class
    list = rules("p { color: red }\n@media all { a { color: blue } }")
    assert_equal("CSSStyleRule", chain(list.item(0)).first)
    assert_equal("CSSMediaRule", chain(list.item(1)).first)
    assert(Dommy::Js::DomInterfaces.polymorphic?(list.item(0)))
  end
end

# WPT: css/cssom/CSSStyleSheet.html — the legacy addRule / removeRule members.
class TestWPTCssStyleSheetAddRule < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    style = @win.document.create_element("style")
    style.text_content = "#foo { height: 100px; }"
    @win.document.body.append_child(style)
    @sheet = style.sheet
  end

  def test_addRule_appends_and_returns_minus_one
    assert_equal(-1, @sheet.add_rule("#foo", "color: red"))
    assert_equal(2, @sheet.css_rules.length)
    assert_equal("#foo { color: red; }", @sheet.css_rules.item(1).css_text)
  end

  def test_addRule_with_an_index_inserts_there
    @sheet.add_rule("#foo", "color: blue", 0)
    assert_equal("#foo { color: blue; }", @sheet.css_rules.item(0).css_text)
  end

  def test_addRule_builds_an_at_rule_by_concatenation
    @sheet.add_rule("@media all", "#foo { color: red }")
    rule = @sheet.css_rules.item(1)
    assert_equal(Dommy::CSSRule::MEDIA_RULE, rule.type)
  end

  # Both arguments default to the string "undefined", and a block that holds no
  # declarations serializes empty.
  def test_addRule_with_no_arguments
    assert_equal(-1, @sheet.add_rule)
    assert_equal("undefined { }", @sheet.css_rules.item(1).css_text)
  end
end
