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
