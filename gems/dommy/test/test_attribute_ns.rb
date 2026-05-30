# frozen_string_literal: true

require_relative "test_helper"

# Namespaced attribute support: Element *AttributeNS, Attr namespace metadata,
# NamedNodeMap NS access, createAttributeNS, and validate-and-extract errors.
# Nokogiri-only behavior (Nokolexbor degrades to the null namespace).
class TestAttributeNS < Minitest::Test
  include DommyTestHelper

  XLINK = Dommy::Internal::Namespaces::XLINK
  EX = "http://example.com/ns"

  def setup
    @win = make_window("<svg></svg>")
    @el = @win.document.query_selector("svg")
  end

  def test_set_get_has_remove
    @el.set_attribute_ns(XLINK, "xlink:href", "x.html")
    assert_equal "x.html", @el.get_attribute_ns(XLINK, "href")
    assert @el.has_attribute_ns?(XLINK, "href")

    @el.remove_attribute_ns(XLINK, "href")
    refute @el.has_attribute_ns?(XLINK, "href")
    assert_nil @el.get_attribute_ns(XLINK, "href")
  end

  # A namespaced attribute and a null-namespace attribute with the same local
  # name are distinct (spec keys attributes by (namespace, localName)).
  def test_null_ns_and_namespaced_coexist
    @el.set_attribute("href", "null-ns")
    @el.set_attribute_ns(XLINK, "xlink:href", "xlink-ns")

    assert_equal "null-ns", @el.get_attribute("href")
    assert_equal "null-ns", @el.get_attribute_ns(nil, "href")
    assert_equal "xlink-ns", @el.get_attribute_ns(XLINK, "href")
  end

  def test_attr_node_metadata
    @el.set_attribute_ns(XLINK, "xlink:href", "x.html")
    attr = @el.get_attribute_node_ns(XLINK, "href")

    assert_equal "xlink:href", attr.name
    assert_equal "href", attr.local_name
    assert_equal XLINK, attr.namespace_uri
    assert_equal "xlink", attr.prefix
    assert_equal "x.html", attr.value
  end

  def test_namespaced_attribute_preserves_case
    @el.set_attribute_ns(EX, "e:FooBar", "v")
    assert_equal "v", @el.get_attribute_ns(EX, "FooBar")
    attr = @el.get_attribute_node_ns(EX, "FooBar")
    assert_equal "FooBar", attr.local_name
  end

  def test_named_node_map_includes_namespaced
    @el.set_attribute_ns(XLINK, "xlink:href", "x.html")
    @el.set_attribute("title", "plain")

    pairs = @el.attributes.map { |a| [a.name, a.namespace_uri] }
    assert_includes pairs, ["xlink:href", XLINK]
    assert_includes pairs, ["title", nil]

    got = @el.attributes.get_named_item_ns(XLINK, "href")
    assert_equal "x.html", got.value
  end

  def test_create_attribute_ns_and_set_attribute_node
    attr = @win.document.create_attribute_ns(XLINK, "xlink:role")
    assert_equal XLINK, attr.namespace_uri
    assert_equal "role", attr.local_name
    assert_nil attr.owner_element

    attr.value = "button"
    @el.attributes.set_named_item_ns(attr)
    assert_equal "button", @el.get_attribute_ns(XLINK, "role")
  end

  def test_attr_value_setter_writes_through
    @el.set_attribute_ns(XLINK, "xlink:href", "a")
    attr = @el.get_attribute_node_ns(XLINK, "href")
    attr.value = "b"
    assert_equal "b", @el.get_attribute_ns(XLINK, "href")
  end

  # WHATWG "set an attribute value": re-setting an existing (namespace,
  # localName) attribute with a different prefix changes only the value —
  # the original prefix / qualified name is preserved.
  def test_set_attribute_ns_preserves_existing_prefix
    @el.set_attribute_ns(EX, "foo:bar", "X")
    @el.set_attribute_ns(EX, "quux:bar", "Y")

    assert_equal 1, @el.attributes.length
    assert_equal "Y", @el.get_attribute_ns(EX, "bar")
    attr = @el.get_attribute_node_ns(EX, "bar")
    assert_equal "foo", attr.prefix
    assert_equal "foo:bar", attr.name
  end

  def test_prefix_with_null_namespace_raises
    assert_raises(Dommy::DOMException::NamespaceError) do
      @el.set_attribute_ns(nil, "p:x", "v")
    end
  end

  def test_xml_prefix_wrong_namespace_raises
    assert_raises(Dommy::DOMException::NamespaceError) do
      @el.set_attribute_ns(EX, "xml:lang", "en")
    end
  end

  def test_invalid_qualified_name_raises
    assert_raises(Dommy::DOMException::InvalidCharacterError) do
      @el.set_attribute_ns(EX, "a:b:c", "v")
    end
    assert_raises(Dommy::DOMException::InvalidCharacterError) do
      @win.document.create_attribute_ns(EX, "")
    end
  end

  def test_js_bridge_round_trip
    @el.__js_call__("setAttributeNS", [XLINK, "xlink:href", "x.html"])
    assert_equal "x.html", @el.__js_call__("getAttributeNS", [XLINK, "href"])
    assert_equal true, @el.__js_call__("hasAttributeNS", [XLINK, "href"])
    @el.__js_call__("removeAttributeNS", [XLINK, "href"])
    assert_equal false, @el.__js_call__("hasAttributeNS", [XLINK, "href"])
  end
end
