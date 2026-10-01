# frozen_string_literal: true

require_relative "test_helper"

# An Attr is a Node outside the tree (DOM §4.9): no parent, children or
# siblings, a node document of its own, and a position at its element.
class TestAttrNode < Minitest::Test
  NODE = Dommy::Node

  def setup
    @doc = Dommy.parse("<div id=a class=k><p id=b>x</p></div><p id=c></p>").document
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
    @c = @doc.get_element_by_id("c")
    @id = @a.get_attribute_node("id")
    @class = @a.get_attribute_node("class")
    @other = Dommy.parse("<p></p>").document
  end

  def test_an_attr_is_outside_the_tree
    %w[parentNode parentElement firstChild lastChild previousSibling nextSibling].each do |key|
      assert_nil @id.__js_get__(key), key
    end
    assert_equal 0, @id.__js_get__("childNodes").length
    refute @id.__js_get__("isConnected")
  end
end
