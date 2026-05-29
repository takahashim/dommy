# frozen_string_literal: true

require_relative "test_helper"

class TestTree < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<ul id='list'><li id='a'>A</li><li id='b'>B</li></ul>")
    @doc = @win.document
    @list = @doc.get_element_by_id("list")
  end

  def test_append_child
    li = @doc.create_element("li")
    li.text_content = "C"
    @list.append_child(li)
    assert_equal(3, @list.children.size)
    assert_equal("C", @list.children[2].text_content)
  end

  def test_insert_before
    li = @doc.create_element("li")
    li.text_content = "X"
    @list.insert_before(li, @doc.get_element_by_id("b"))
    assert_equal(["a", "X", "b"], @list.children.to_a.map { |c| c.id.empty? ? c.text_content : c.id })
  end

  def test_remove_child
    a = @doc.get_element_by_id("a")
    @list.remove_child(a)
    assert_equal(1, @list.children.size)
    assert_nil(@doc.get_element_by_id("a"))
  end

  def test_remove_self
    @doc.get_element_by_id("a").remove
    assert_nil(@doc.get_element_by_id("a"))
  end

  def test_replace_child
    a = @doc.get_element_by_id("a")
    new_el = @doc.create_element("span")
    new_el.text_content = "Z"
    @list.replace_child(new_el, a)
    assert_equal("SPAN", @list.children[0].tag_name)
    assert_equal("Z", @list.children[0].text_content)
  end

  def test_clone_node_shallow
    a = @doc.get_element_by_id("a")
    clone = a.clone_node(false)
    assert_equal("LI", clone.tag_name)
    assert_equal("a", clone.id)
    # children excluded in shallow clone
    assert_equal(0, clone.children.size)
  end

  def test_clone_node_deep
    @list.inner_html = "<li><span>x</span></li>"
    src = @list.children[0]
    clone = src.clone_node(true)
    assert_equal("LI", clone.tag_name)
    refute_nil(clone.query_selector("span"))
  end

  def test_parent_node
    a = @doc.get_element_by_id("a")
    assert_same(@list.__dommy_backend_node__, a.parent_node.__dommy_backend_node__)
  end

  def test_query_selector_within_subtree
    el = @list.query_selector("#b")
    refute_nil(el)
    assert_equal("b", el.id)
  end

  def test_closest
    @list.inner_html = "<li><span class='c'><b id='target'>hi</b></span></li>"
    target = @doc.get_element_by_id("target")
    li = target.closest("li")
    assert_equal("LI", li.tag_name)
  end
end
