# frozen_string_literal: true

require_relative "test_helper"

class TestEquality < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_same_node_for_identity
    el = @doc.create_element("div")
    assert(el.same_node?(el))
  end

  def test_same_node_false_for_different_instances
    a = @doc.create_element("div")
    b = @doc.create_element("div")
    refute(a.same_node?(b))
  end

  def test_equal_node_for_structurally_identical
    a = @doc.create_element("div")
    a.set_attribute("class", "foo")
    a.text_content = "hi"
    b = @doc.create_element("div")
    b.set_attribute("class", "foo")
    b.text_content = "hi"
    assert(a.equal_node?(b))
  end

  def test_equal_node_false_on_different_tag
    a = @doc.create_element("div")
    b = @doc.create_element("p")
    refute(a.equal_node?(b))
  end

  def test_equal_node_false_on_different_attributes
    a = @doc.create_element("div")
    a.set_attribute("id", "1")
    b = @doc.create_element("div")
    b.set_attribute("id", "2")
    refute(a.equal_node?(b))
  end

  def test_equal_node_false_on_different_children
    a = @doc.create_element("div")
    a.append_child(@doc.create_element("span"))
    b = @doc.create_element("div")
    b.append_child(@doc.create_element("p"))
    refute(a.equal_node?(b))
  end

  def test_clone_is_equal_to_source
    src = @doc.create_element("div")
    src.set_attribute("class", "a b")
    src.append_child(@doc.create_element("span"))
    clone = src.clone_node(true)
    assert(src.equal_node?(clone))
  end
end
