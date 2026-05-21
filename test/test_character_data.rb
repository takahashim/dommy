# frozen_string_literal: true

require_relative "test_helper"

class TestCharacterData < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_text_node_data_round_trip
    t = @doc.create_text_node("hello")
    assert_equal("hello", t.data)
    t.data = "world"
    assert_equal("world", t.text_content)
  end

  def test_text_node_node_value
    t = @doc.create_text_node("a")
    t.node_value = "b"
    assert_equal("b", t.node_value)
    assert_equal("b", t.data)
    assert_equal("b", t.text_content)
  end

  def test_text_node_remove_unlinks
    p = @doc.create_element("p")
    t = @doc.create_text_node("x")
    p.append_child(t)
    t.remove
    assert_equal("", p.text_content)
  end

  def test_create_comment
    c = @doc.create_comment(" howdy ")
    assert_kind_of(Dommy::CommentNode, c)
    assert_equal(8, c[:nodeType])
    assert_equal(" howdy ", c.data)
  end

  def test_comment_data_set
    c = @doc.create_comment("a")
    c.data = "b"
    assert_equal("b", c.data)
  end

  def test_comment_in_tree
    div = @doc.create_element("div")
    div.append_child(@doc.create_comment(" tag "))
    # CommentNode is exposed via children only when comment is a child
    # node; child_nodes includes it.
    assert_equal(1, div.child_nodes.size)
  end
end
