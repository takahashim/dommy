# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Element.getAttributeNames().
# WPT: dom/nodes/Element-getAttributeNames.html
#
# getAttributeNames() is exposed through the JS bridge only, so tests
# drive it via __js_call__ (mirroring how the QuickJS layer invokes it).
class TestWPTElementGetAttributeNames < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def names(el)
    el.__js_call__("getAttributeNames", [])
  end

  def test_returns_array
    @doc.body.inner_html = "<div id='x'></div>"
    el = @doc.get_element_by_id("x")
    assert_kind_of(Array, names(el))
  end

  def test_empty_element_returns_empty_array
    @doc.body.inner_html = "<div></div>"
    el = @doc.query_selector("div")
    assert_equal([], names(el))
  end

  def test_lists_all_attribute_names
    @doc.body.inner_html = "<div id='x' class='c' data-y='42'></div>"
    el = @doc.get_element_by_id("x")
    assert_equal(%w[id class data-y].sort, names(el).sort)
  end

  # WPT asserts insertion/parse order is preserved.
  def test_preserves_attribute_order
    @doc.body.inner_html = "<div id='x' class='c' data-y='42'></div>"
    el = @doc.get_element_by_id("x")
    assert_equal(%w[id class data-y], names(el))
  end

  # HTML parsing/serialization lowercases attribute qualified names.
  def test_names_are_lowercased
    @doc.body.inner_html = "<div id='e'></div>"
    el = @doc.get_element_by_id("e")
    el.set_attribute("Foo", "1")
    assert_includes(names(el), "foo")
    refute_includes(names(el), "Foo")
  end

  def test_reflects_added_attribute
    @doc.body.inner_html = "<div id='e'></div>"
    el = @doc.get_element_by_id("e")
    el.set_attribute("data-new", "v")
    assert_includes(names(el), "data-new")
  end

  def test_reflects_removed_attribute
    @doc.body.inner_html = "<div id='e' class='c'></div>"
    el = @doc.get_element_by_id("e")
    el.remove_attribute("class")
    refute_includes(names(el), "class")
  end

  # Each call returns a fresh snapshot, not a live list.
  def test_returns_fresh_array_each_call
    @doc.body.inner_html = "<div id='x'></div>"
    el = @doc.get_element_by_id("x")
    refute_same(names(el), names(el))
  end
end
