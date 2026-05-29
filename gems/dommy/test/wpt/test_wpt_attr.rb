# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Attr and NamedNodeMap.
# WPT: dom/nodes/attributes.html, Element-setAttribute.html,
# Document-createAttribute.html, NamedNodeMap.html,
# attributes-namednodemap.html
class TestWPTAttrBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- createAttribute ----
  # WPT: Document-createAttribute.html

  def test_createAttribute_returns_attr
    attr = @doc.create_attribute("data-x")
    assert_kind_of(Dommy::Attr, attr)
  end

  def test_createAttribute_lowercases_name
    attr = @doc.create_attribute("DATA-X")
    assert_equal("data-x", attr.name)
  end

  def test_createAttribute_default_value_is_empty_string
    attr = @doc.create_attribute("data-y")
    assert_equal("", attr.value)
  end

  def test_createAttribute_no_owner_initially
    attr = @doc.create_attribute("data-z")
    assert_nil(attr.owner_element)
  end

  # ---- Attr.value get/set on detached attr ----

  def test_detached_value_setter_then_getter
    attr = @doc.create_attribute("data-q")
    attr.value = "hello"
    assert_equal("hello", attr.value)
  end

  # ---- Attr.nodeType is 2 ----
  # WPT: nodeType.html

  def test_attr_nodeType_is_2
    attr = @doc.create_attribute("data-n")
    assert_equal(2, attr.__js_get__("nodeType"))
  end

  def test_attr_nodeName_matches_name
    attr = @doc.create_attribute("data-n")
    assert_equal("data-n", attr.__js_get__("nodeName"))
  end

  def test_attr_nodeValue_matches_value
    attr = @doc.create_attribute("data-n")
    attr.value = "v"
    assert_equal("v", attr.__js_get__("nodeValue"))
  end
end

class TestWPTAttrOnElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='c' data-y='42'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
  end

  # ---- getAttributeNode ----
  # WPT: Element-getAttributeNode.html

  def test_getAttributeNode_returns_Attr_for_existing
    attr = @el.get_attribute_node("class")
    assert_kind_of(Dommy::Attr, attr)
    assert_equal("class", attr.name)
    assert_equal("c", attr.value)
  end

  def test_getAttributeNode_returns_nil_for_missing
    assert_nil(@el.get_attribute_node("nope"))
  end

  def test_attribute_node_value_reflects_element_mutation
    attr = @el.get_attribute_node("class")
    @el.set_attribute("class", "new-value")
    assert_equal("new-value", attr.value)
  end

  def test_attribute_node_value_setter_writes_back_to_element
    attr = @el.get_attribute_node("class")
    attr.value = "changed"
    assert_equal("changed", @el.get_attribute("class"))
  end

  def test_owner_element_is_set
    attr = @el.get_attribute_node("class")
    assert_same(@el, attr.owner_element)
  end

  # ---- setAttributeNode / removeAttributeNode ----
  # WPT: Element-setAttributeNode.html

  def test_setAttributeNode_attaches_attr
    attr = @doc.create_attribute("data-z")
    attr.value = "zz"
    @el.set_attribute_node(attr)
    assert_equal("zz", @el.get_attribute("data-z"))
  end

  def test_setAttributeNode_associates_owner
    attr = @doc.create_attribute("data-z")
    @el.set_attribute_node(attr)
    assert_same(@el, attr.owner_element)
  end

  def test_removeAttributeNode_detaches
    attr = @el.get_attribute_node("class")
    @el.remove_attribute_node(attr)
    refute(@el.has_attribute?("class"))
  end
end

class TestWPTNamedNodeMap < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='c' data-y='42'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
    @map = @el.attributes
  end

  # ---- length / item / iteration ----
  # WPT: NamedNodeMap.html

  def test_length_returns_attribute_count
    assert_equal(3, @map.length)
  end

  def test_item_returns_Attr_at_index
    attr = @map.item(0)
    assert_kind_of(Dommy::Attr, attr)
  end

  def test_item_out_of_range_returns_nil
    assert_nil(@map.item(99))
  end

  def test_bracket_access_by_index
    assert_kind_of(Dommy::Attr, @map[0])
  end

  def test_bracket_access_by_name
    attr = @map["class"]
    assert_equal("class", attr.name)
  end

  def test_each_yields_all_attrs
    seen = []
    @map.each { |a| seen << a.name }
    assert_equal(3, seen.length)
    assert_includes(seen, "class")
    assert_includes(seen, "data-y")
    assert_includes(seen, "id")
  end

  # ---- getNamedItem / setNamedItem / removeNamedItem ----
  # WPT: NamedNodeMap-getNamedItem.html, etc.

  def test_getNamedItem_returns_Attr
    attr = @map.get_named_item("class")
    assert_kind_of(Dommy::Attr, attr)
    assert_equal("c", attr.value)
  end

  def test_getNamedItem_lowercases_name
    attr = @map.get_named_item("CLASS")
    refute_nil(attr)
    assert_equal("class", attr.name)
  end

  def test_getNamedItem_missing_returns_nil
    assert_nil(@map.get_named_item("missing"))
  end

  def test_setNamedItem_attaches_and_returns_attr
    new_attr = @doc.create_attribute("data-new")
    new_attr.value = "yes"
    @map.set_named_item(new_attr)
    assert_equal("yes", @el.get_attribute("data-new"))
  end

  def test_removeNamedItem_detaches
    @map.remove_named_item("class")
    refute(@el.has_attribute?("class"))
  end

  def test_removeNamedItem_returns_detached_Attr_with_value
    attr = @map.remove_named_item("data-y")
    assert_equal("42", attr.value)
  end

  def test_removeNamedItem_missing_returns_nil
    assert_nil(@map.remove_named_item("nope"))
  end
end
