# frozen_string_literal: true

require_relative "test_helper"

class TestCSSStyleSheetStub < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_link_with_stylesheet_rel_has_sheet
    link = @doc.create_element("link")
    link.rel = "stylesheet"
    link.href = "/x.css"
    assert_kind_of(Dommy::CSSStyleSheet, link.sheet)
  end

  def test_link_without_stylesheet_rel_returns_nil
    link = @doc.create_element("link")
    link.rel = "icon"
    assert_nil(link.sheet)
  end

  def test_link_sheet_carries_href_and_type
    link = @doc.create_element("link")
    link.rel = "stylesheet"
    link.href = "/main.css"
    sheet = link.sheet
    assert_equal("/main.css", sheet.href)
    assert_equal("text/css", sheet.type)
  end

  def test_link_sheet_owner_node_back_reference
    link = @doc.create_element("link")
    link.rel = "stylesheet"
    assert_same(link, link.sheet.owner_node)
  end

  def test_link_sheet_cached_across_accesses
    link = @doc.create_element("link")
    link.rel = "stylesheet"
    assert_same(link.sheet, link.sheet)
  end

  def test_style_element_always_has_sheet
    style = @doc.create_element("style")
    assert_kind_of(Dommy::CSSStyleSheet, style.sheet)
  end

  def test_style_sheet_starts_empty
    style = @doc.create_element("style")
    assert_equal(0, style.sheet.css_rules.length)
  end
end

class TestCSSStyleSheetMutation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @style = @doc.create_element("style")
    @sheet = @style.sheet
  end

  def test_insertRule_appends_by_default
    @sheet.insert_rule("p { color: red }")
    assert_equal(1, @sheet.css_rules.length)
    assert_equal("p { color: red }", @sheet.css_rules.item(0).css_text)
  end

  def test_insertRule_at_index
    @sheet.insert_rule("p {}")
    @sheet.insert_rule("a {}", 0)
    assert_equal("a {}", @sheet.css_rules.item(0).css_text)
    assert_equal("p {}", @sheet.css_rules.item(1).css_text)
  end

  def test_insertRule_returns_index
    idx = @sheet.insert_rule("p {}")
    assert_equal(0, idx)
    idx2 = @sheet.insert_rule("a {}")
    assert_equal(1, idx2)
  end

  def test_insertRule_out_of_range_raises_IndexSizeError
    assert_raises(Dommy::DOMException::IndexSizeError) { @sheet.insert_rule("p {}", 5) }
  end

  def test_deleteRule
    @sheet.insert_rule("p {}")
    @sheet.insert_rule("a {}")
    @sheet.delete_rule(0)
    assert_equal(1, @sheet.css_rules.length)
    assert_equal("a {}", @sheet.css_rules.item(0).css_text)
  end

  def test_deleteRule_out_of_range_raises
    assert_raises(Dommy::DOMException::IndexSizeError) { @sheet.delete_rule(0) }
  end

  def test_replaceSync_replaces_all
    @sheet.insert_rule("p {}")
    @sheet.replace_sync("body { margin: 0 }")
    assert_equal(1, @sheet.css_rules.length)
    assert_equal("body { margin: 0 }", @sheet.css_rules.item(0).css_text)
  end

  def test_replaceSync_empty_clears_rules
    @sheet.insert_rule("p {}")
    @sheet.replace_sync("")
    assert_equal(0, @sheet.css_rules.length)
  end

  def test_disabled_default_false
    refute(@sheet.disabled)
  end

  def test_disabled_setter
    @sheet.disabled = true
    assert(@sheet.disabled)
  end

  def test_js_bridge_insertRule
    @sheet.__js_call__("insertRule", ["p {}", 0])
    assert_equal(1, @sheet.css_rules.length)
  end
end

class TestCSSRuleListAndCSSRule < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @sheet = @doc.create_element("style").sheet
    @sheet.insert_rule("p { color: red }")
    @sheet.insert_rule("a { color: blue }")
  end

  def test_css_rules_is_CSSRuleList
    assert_kind_of(Dommy::CSSRuleList, @sheet.css_rules)
  end

  def test_rule_list_length
    assert_equal(2, @sheet.css_rules.length)
  end

  def test_rule_list_item
    assert_equal("p { color: red }", @sheet.css_rules.item(0).css_text)
  end

  def test_rule_list_indexer
    assert_equal("a { color: blue }", @sheet.css_rules[1].css_text)
  end

  def test_rule_list_iteration
    seen = []
    @sheet.css_rules.each { |r| seen << r.css_text }
    assert_equal(["p { color: red }", "a { color: blue }"], seen)
  end

  def test_rule_list_out_of_range_returns_nil
    assert_nil(@sheet.css_rules.item(99))
  end

  def test_rule_parent_sheet_back_reference
    assert_same(@sheet, @sheet.css_rules.item(0).parent_style_sheet)
  end

  def test_rule_type_is_STYLE_RULE
    rule = @sheet.css_rules.item(0)
    assert_equal(Dommy::CSSRule::STYLE_RULE, rule.type)
  end

  def test_rule_cssText_setter
    rule = @sheet.css_rules.item(0)
    rule.css_text = "p { color: green }"
    assert_equal("p { color: green }", rule.css_text)
  end
end

# The CSSOM rule objects expose selectorText / style / nested cssRules parsed
# off the source slice (not just opaque cssText).
class TestCSSRuleAccessors < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def sheet_for(css)
    style = @doc.create_element("style")
    style.text_content = css
    @doc.head.append_child(style)
    style.sheet
  end

  def test_style_element_splits_into_one_rule_per_rule
    sheet = sheet_for("p { color: red } a { color: blue }")
    assert_equal(2, sheet.css_rules.length)
    assert_equal("p", sheet.css_rules[0].selector_text)
    assert_equal("a", sheet.css_rules[1].selector_text)
  end

  def test_style_rule_style_reads_declarations
    rule = sheet_for("p { color: red; font-size: 12px }").css_rules[0]
    assert_equal("red", rule.style.get_property_value("color"))
    assert_equal("12px", rule.style.get_property_value("font-size"))
    assert_equal("", rule.style.get_property_value("margin"))
  end

  def test_style_priority_is_reported
    rule = sheet_for("p { color: red !important }").css_rules[0]
    assert_equal("important", rule.style.get_property_priority("color"))
  end

  def test_style_setProperty_rebuilds_css_text
    rule = sheet_for("p { color: red }").css_rules[0]
    rule.style.set_property("color", "green")
    assert_equal("green", rule.style.get_property_value("color"))
    assert_includes(rule.css_text, "color: green")
  end

  def test_media_rule_type_condition_and_nested_rules
    rule = sheet_for("@media (min-width: 600px) { p { color: green } }").css_rules[0]
    assert_equal(Dommy::CSSRule::MEDIA_RULE, rule.type)
    assert_equal("(min-width: 600px)", rule.condition_text)
    assert_equal(1, rule.css_rules.length)
    assert_equal("green", rule.css_rules[0].style.get_property_value("color"))
  end

  def test_font_face_rule_type
    rule = sheet_for("@font-face { font-family: Foo; src: url(x.woff2) }").css_rules[0]
    assert_equal(Dommy::CSSRule::FONT_FACE_RULE, rule.type)
    assert_nil(rule.style)
  end

  def test_selector_text_setter_rebuilds
    rule = sheet_for("p { color: red }").css_rules[0]
    rule.selector_text = "div"
    assert_equal("div", rule.selector_text)
    assert_includes(rule.css_text, "div")
  end

  def test_js_bridge_exposes_selector_and_style
    rule = sheet_for("p { color: red }").css_rules[0]
    assert_equal("p", rule.__js_get__("selectorText"))
    style = rule.__js_get__("style")
    assert_equal("red", style.__js_get__("color"))
  end
end

# <link rel=stylesheet> participates in the cascade once a host environment
# fills its CSS via set_stylesheet_text (Dommy fetches nothing itself).
class TestLinkStylesheetCascade < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.inner_html = "<p id='x'>hi</p>"
  end

  def link(attrs = "rel=stylesheet href=/app.css")
    @doc.head.inner_html = "<link #{attrs}>"
    @doc.query_selector("link")
  end

  def color
    @win.get_computed_style(@doc.query_selector("#x")).get_property_value("color")
  end

  def test_unfilled_link_contributes_nothing
    link
    assert_equal "rgb(0, 0, 0)", color
  end

  def test_filled_link_participates_in_cascade
    link.set_stylesheet_text("#x { color: red }")
    assert_equal "rgb(255, 0, 0)", color
  end

  def test_filled_link_splits_into_css_rules
    sheet = link.set_stylesheet_text("#x { color: red } p { font-size: 20px }")
    assert_equal 2, sheet.css_rules.length
    assert_equal "#x", sheet.css_rules[0].selector_text
  end

  def test_disabled_link_sheet_is_muted
    el = link
    el.set_stylesheet_text("#x { color: red }")
    el.sheet.disabled = true
    assert_equal "rgb(0, 0, 0)", color
  end

  def test_media_attribute_gates_the_link
    link("rel=stylesheet media='(min-width: 9999px)' href=/big.css").set_stylesheet_text("#x { color: red }")
    assert_equal "rgb(0, 0, 0)", color
  end

  def test_non_stylesheet_link_has_no_sheet_text_hook
    el = link("rel=icon href=/favicon.ico")
    assert_nil el.set_stylesheet_text("#x { color: red }")
    assert_equal "rgb(0, 0, 0)", color
  end

  def test_refill_replaces_previous_rules
    el = link
    el.set_stylesheet_text("#x { color: red }")
    el.set_stylesheet_text("#x { color: blue }")
    assert_equal "rgb(0, 0, 255)", color
  end
end
