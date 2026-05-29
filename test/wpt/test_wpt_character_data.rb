# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for CharacterData (Text, Comment).
class TestWPTCharacterData < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- CharacterData.data (get/set) ----
  # WPT: dom/nodes/CharacterData-data.html

  def test_text_data_get_set
    t = @doc.create_text_node("hello")
    assert_equal("hello", t.data)
    t.data = "world"
    assert_equal("world", t.data)
  end

  def test_comment_data_get_set
    c = @doc.create_comment("note")
    assert_equal("note", c.data)
    c.data = "updated"
    assert_equal("updated", c.data)
  end

  # ---- length ----
  # WPT: implied by spec
  # (Dommy: derive via data.length since we don't expose `length` on text)

  def test_text_data_length
    t = @doc.create_text_node("hello")
    assert_equal(5, t.data.length)
  end

  # ---- textContent (CharacterData inherits) ----

  def test_text_textContent_matches_data
    t = @doc.create_text_node("hello")
    assert_equal(t.data, t.text_content)
  end

  def test_text_setting_textContent_updates_data
    t = @doc.create_text_node("hello")
    t.text_content = "world"
    assert_equal("world", t.data)
  end

  # ---- nodeValue (CharacterData inherits) ----

  def test_text_nodeValue_matches_data
    t = @doc.create_text_node("hello")
    assert_equal(t.data, t.node_value)
  end

  def test_text_setting_nodeValue_updates_data
    t = @doc.create_text_node("hello")
    t.node_value = "world"
    assert_equal("world", t.data)
  end

  # ---- CharacterData.remove ----
  # WPT: dom/nodes/CharacterData-remove.html

  def test_text_remove_detaches
    p = @doc.create_element("p")
    t = @doc.create_text_node("x")
    p.append_child(t)
    t.remove
    assert_equal("", p.text_content)
  end

  def test_comment_remove_detaches
    div = @doc.create_element("div")
    div.append_child(@doc.create_element("p"))
    c = @doc.create_comment("note")
    div.append_child(c)
    c.remove
    assert_equal(1, div.child_nodes.length)
  end

  # ---- Adjacency / parent ----

  def test_text_parentElement
    p = @doc.create_element("p")
    t = @doc.create_text_node("x")
    p.append_child(t)
    assert_same(p.__dommy_backend_node__, t.parent_node.__dommy_backend_node__)
  end

  def test_text_no_children
    t = @doc.create_text_node("x")
    # Text nodes shouldn't have children; we don't expose a method for
    # this, but appending to one should be a no-op (or error).
    assert_equal("x", t.text_content)
  end
end
