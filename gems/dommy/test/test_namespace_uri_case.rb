# frozen_string_literal: true

require_relative "test_helper"

# A namespace URI is an opaque string: `fooNamespace` and `foonamespace` are
# two namespaces, and `HTTP://WWW.W3.ORG/1999/XHTML` is not the HTML one. The
# backend used to fold a created element's or attribute's URI to lower case in
# an HTML document, which the wrappers' own copy of the name hid.
class TestNamespaceUriCase < Minitest::Test
  def setup
    @doc = Dommy.parse("<p id=p></p>").document
    @p = @doc.get_element_by_id("p")
  end

  def test_an_element_keeps_its_namespace_as_written
    el = @doc.create_element_ns("fooNamespace", "prefix:elem")
    assert_equal ["fooNamespace", "prefix", "elem", "prefix:elem"], [el.namespace_uri, el.element_prefix, el.local_name, el.tag_name]
    assert_equal "fooNamespace", el.clone_node(true).namespace_uri
    assert_equal "fooNamespace", el.lookup_namespace_uri("prefix")
  end

  def test_an_upper_cased_html_namespace_is_not_the_html_one
    el = @doc.create_element_ns("HTTP://WWW.W3.ORG/1999/XHTML", "div")
    assert_equal "HTTP://WWW.W3.ORG/1999/XHTML", el.namespace_uri
    assert_equal "div", el.tag_name
    refute_kind_of Dommy::HTMLElement, el
  end

  def test_an_attribute_is_found_by_its_namespace_as_written
    @p.set_attribute_ns("attrNamespace", "a:x", "1")
    assert_equal "1", @p.get_attribute_ns("attrNamespace", "x")
    assert_nil @p.get_attribute_ns("attrnamespace", "x")
    assert @p.has_attribute_ns?("attrNamespace", "x")
    assert_equal "attrNamespace", @p.get_attribute_node_ns("attrNamespace", "x").namespace_uri
  end
end
