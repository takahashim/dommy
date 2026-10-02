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

  # An Attr has no descendants, and two are equal when their namespace,
  # local name and value are (the prefix aside).
  def test_an_attr_contains_and_equals
    assert @id.__js_call__("contains", [@id])
    refute @id.__js_call__("contains", [@class])
    a = @doc.create_attribute_ns("urn:a", "p:x")
    assert a.__js_call__("isEqualNode", [@doc.create_attribute_ns("urn:a", "q:x")])
    refute a.__js_call__("isEqualNode", [@doc.create_attribute_ns("urn:b", "p:x")])
  end

  def test_an_element_contains_its_attributes
    assert_equal NODE::DOCUMENT_POSITION_CONTAINED_BY | NODE::DOCUMENT_POSITION_FOLLOWING, @a.compare_document_position(@id)
    assert_equal NODE::DOCUMENT_POSITION_CONTAINS | NODE::DOCUMENT_POSITION_PRECEDING, @id.compare_document_position(@a)
  end

  def test_attributes_of_one_element_compare_in_list_order
    specific = NODE::DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC
    assert_equal specific | NODE::DOCUMENT_POSITION_FOLLOWING, @id.compare_document_position(@class)
    assert_equal specific | NODE::DOCUMENT_POSITION_PRECEDING, @class.compare_document_position(@id)
  end

  # An attribute comes before its element's children, and is no ancestor of
  # them.
  def test_an_attribute_stands_at_its_element
    assert_equal NODE::DOCUMENT_POSITION_FOLLOWING, @id.compare_document_position(@b)
    assert_equal NODE::DOCUMENT_POSITION_PRECEDING, @b.compare_document_position(@id)
    assert_equal NODE::DOCUMENT_POSITION_CONTAINS | NODE::DOCUMENT_POSITION_PRECEDING,
      @b.get_attribute_node("id").compare_document_position(@a)
    assert_equal NODE::DOCUMENT_POSITION_FOLLOWING, @b.get_attribute_node("id").compare_document_position(@c.get_attribute_node("id"))
    assert_equal NODE::DOCUMENT_POSITION_PRECEDING, @c.compare_document_position(@b.get_attribute_node("id"))
  end

  def test_adopting_an_attr_keeps_it_on_its_element
    assert_same @id, @other.adopt_node(@id)
    assert_same @a, @id.owner_element
    assert_same @other, @id.owner_document
  end

  def test_a_removed_attribute_keeps_its_node_document
    @a.remove_attribute_node(@id)

    assert_nil @id.owner_element
    assert_same @doc, @id.owner_document
  end

  def test_appending_an_attribute_sets_its_node_document
    attr = @other.create_attribute("title")
    @a.set_attribute_node(attr)
    assert_same @doc, attr.owner_document

    @a.remove_attribute_node(attr)
    assert_same @doc, attr.owner_document
  end

  def test_adopting_an_element_moves_its_attributes
    @other.adopt_node(@a)
    assert_same @other, @id.owner_document

    @a.remove_attribute_node(@id)
    assert_same @other, @id.owner_document
  end

  # An Attr in no namespace writes itself, even when an attribute in another
  # namespace shares its qualified name and comes first.
  def test_an_attribute_in_no_namespace_writes_itself
    el = @doc.create_element("p")
    el.set_attribute_ns("urn:x", "a", "ns")
    attr = @doc.create_attribute("a")
    attr.value = "plain"

    assert_nil el.set_attribute_node(attr)
    attr.value = "changed"
    assert_equal [["urn:x", "ns"], [nil, "changed"]], el.attributes.map { |a| [a.namespace_uri, a.value] }
  end
end
