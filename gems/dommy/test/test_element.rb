# frozen_string_literal: true

require_relative "test_helper"

class TestElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'><p class='para'>Hello <b>World</b></p></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @p = @doc.query_selector("p")
  end

  def test_tag_name_uppercased
    assert_equal("DIV", @root.tag_name)
    assert_equal("P", @p.tag_name)
  end

  def test_id_get_set
    @root.id = "renamed"
    assert_equal("renamed", @root.id)
    assert_equal("renamed", @root.get_attribute("id"))
  end

  def test_class_name_get_set
    @p.class_name = "foo bar"
    assert_equal("foo bar", @p.class_name)
    assert_equal("foo bar", @p.get_attribute("class"))
  end

  def test_text_content_returns_descendant_text
    assert_equal("Hello World", @p.text_content)
  end

  def test_text_content_set_replaces_children
    @p.text_content = "replaced"
    assert_equal("replaced", @p.text_content)
    assert_equal(0, @p.children.size)
  end

  def test_inner_html_get
    assert_equal("Hello <b>World</b>", @p.inner_html.strip)
  end

  def test_inner_html_set_reparses
    @root.inner_html = "<a href='/x'>link</a>"
    a = @root.query_selector("a")
    refute_nil(a)
    assert_equal("link", a.text_content)
    assert_equal("/x", a.get_attribute("href"))
  end

  def test_index_accessor_camelcase
    assert_equal("P", @p[:tagName])
    @p[:className] = "via-index"
    assert_equal("via-index", @p.class_name)
  end

  def test_first_element_child
    assert_equal("B", @p.first_element_child.tag_name)
  end

  def test_parent_element
    assert_equal("DIV", @p.parent_element.tag_name)
  end

  def test_children_is_live
    children = @root.children
    @root.append_child(@doc.create_element("span"))
    assert_equal(2, children.size)
  end
end
