# frozen_string_literal: true

require_relative "test_helper"

class TestAttrAndNamedNodeMap < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='foo bar' data-role='primary'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
  end

  def test_attributes_returns_named_node_map
    assert_kind_of(Dommy::NamedNodeMap, @el.attributes)
  end

  def test_attributes_length
    assert_equal(3, @el.attributes.length)
  end

  def test_attributes_item_by_index
    a0 = @el.attributes.item(0)
    refute_nil(a0)
    assert_kind_of(Dommy::Attr, a0)
  end

  def test_attributes_get_named_item
    attr = @el.attributes.get_named_item("class")
    refute_nil(attr)
    assert_equal("foo bar", attr.value)
  end

  def test_attributes_get_named_item_missing
    assert_nil(@el.attributes.get_named_item("nope"))
  end

  def test_attributes_method_missing_property_access
    # Note: `attributes.class` would shadow Ruby's Object#class; use
    # bracket notation for any name that collides with a built-in.
    @el.set_attribute("foo-bar", "baz")
    direct = @el.attributes["foo-bar"]
    refute_nil(direct)
    assert_equal("baz", direct.value)
  end

  def test_attributes_bracket_access
    attr = @el.attributes["data-role"]
    assert_equal("primary", attr.value)
  end

  def test_attributes_iterable
    names = @el.attributes.map(&:name)
    assert_includes(names, "id")
    assert_includes(names, "class")
    assert_includes(names, "data-role")
  end

  def test_get_attribute_node_returns_attr
    attr = @el.get_attribute_node("id")
    refute_nil(attr)
    assert_equal("x", attr.value)
    assert_same(@el, attr.owner_element)
  end

  def test_attr_value_set_propagates
    attr = @el.get_attribute_node("class")
    attr.value = "primary"
    assert_equal("primary", @el.get_attribute("class"))
  end

  def test_set_attribute_node_attaches
    attr = @doc.create_attribute("data-new")
    attr.value = "yes"
    @el.set_attribute_node(attr)
    assert_equal("yes", @el.get_attribute("data-new"))
    assert_same(@el, attr.owner_element)
  end

  def test_remove_attribute_node_detaches
    attr = @el.get_attribute_node("data-role")
    @el.remove_attribute_node(attr)
    refute(@el.has_attribute?("data-role"))
  end

  def test_attributes_remove_named_item
    @el.attributes.remove_named_item("class")
    refute(@el.has_attribute?("class"))
  end

  def test_attr_node_type_is_two
    attr = @el.get_attribute_node("id")
    assert_equal(2, attr.__js_get__("nodeType"))
  end

  def test_attr_clone_node_detached
    attr = @el.get_attribute_node("id")
    clone = attr.__js_call__("cloneNode", [])
    assert_kind_of(Dommy::Attr, clone)
    assert_nil(clone.owner_element)
    assert_equal("x", clone.value)
  end

  def test_document_create_attribute
    attr = @doc.create_attribute("href")
    assert_kind_of(Dommy::Attr, attr)
    assert_equal("href", attr.name)
    assert_equal("", attr.value)
    assert_nil(attr.owner_element)
  end
end
