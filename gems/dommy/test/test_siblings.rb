# frozen_string_literal: true

require_relative "test_helper"

class TestSiblings < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<ul id='l'><li id='a'>A</li>text<li id='b'>B</li><li id='c'>C</li></ul>")
    @doc = @win.document
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
    @c = @doc.get_element_by_id("c")
  end

  def test_next_sibling_returns_text_node
    ns = @a.next_sibling
    assert_equal("text", ns.text_content)
  end

  def test_next_element_sibling_skips_text
    nes = @a.next_element_sibling
    assert_equal("b", nes.id)
  end

  def test_previous_element_sibling
    assert_equal("b", @c.previous_element_sibling.id)
  end

  def test_no_sibling_returns_nil
    assert_nil(@c.next_element_sibling)
    assert_nil(@a.previous_element_sibling)
  end

  def test_child_node_helpers
    list = @doc.get_element_by_id("l")
    assert_equal(4, list.child_nodes.size)
    assert_equal(3, list.child_element_count)
    assert(list.has_child_nodes?)
  end

  def test_first_last_child
    list = @doc.get_element_by_id("l")
    assert_equal("a", list.first_element_child.id)
    assert_equal("c", list.last_element_child.id)
  end
end
