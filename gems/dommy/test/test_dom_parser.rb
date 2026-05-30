# frozen_string_literal: true

require_relative "test_helper"

class TestDOMParser < Minitest::Test
  def setup
    @parser = Dommy::DOMParser.new
  end

  def test_parseFromString_returns_Document
    doc = @parser.parse_from_string("<html><body><p>x</p></body></html>", "text/html")
    assert_kind_of(Dommy::Document, doc)
  end

  def test_parseFromString_body_has_content
    doc = @parser.parse_from_string("<html><body><p id='x'>hi</p></body></html>", "text/html")
    assert_equal("hi", doc.get_element_by_id("x").text_content)
  end

  def test_parseFromString_default_mime_is_html
    doc = @parser.parse_from_string("<p>x</p>")
    assert_kind_of(Dommy::Document, doc)
  end

  def test_parseFromString_unsupported_mime_raises
    # `type` is a WebIDL enum (DOMParserSupportedType), so an out-of-enum value
    # is a TypeError, not a DOMException.
    assert_raises(Dommy::Bridge::TypeError) do
      @parser.parse_from_string("x", "text/json")
    end
  end

  def test_parseFromString_empty_string_returns_empty_document
    doc = @parser.parse_from_string("", "text/html")
    assert_kind_of(Dommy::Document, doc)
    # Body should exist (empty).
    refute_nil(doc.body)
  end

  def test_parsed_document_is_independent
    doc1 = @parser.parse_from_string("<p>a</p>")
    doc2 = @parser.parse_from_string("<p>b</p>")
    refute_same(doc1, doc2)
    assert_equal("a", doc1.query_selector("p").text_content)
    assert_equal("b", doc2.query_selector("p").text_content)
  end

  def test_parseFromString_via_js_bridge
    doc = @parser.__js_call__("parseFromString", ["<p>x</p>", "text/html"])
    assert_kind_of(Dommy::Document, doc)
  end

  def test_xml_mime_uses_xml_parser
    doc = @parser.parse_from_string("<root><a/></root>", "application/xml")
    assert_kind_of(Dommy::Document, doc)
  end
end

class TestXMLSerializer < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @serializer = Dommy::XMLSerializer.new
  end

  def test_serializes_element
    el = @doc.create_element("p")
    el.text_content = "hi"
    s = @serializer.serialize_to_string(el)
    assert_includes(s, "<p")
    assert_includes(s, "hi")
  end

  def test_serializes_with_attributes
    el = @doc.create_element("a")
    el.set_attribute("href", "/x")
    s = @serializer.serialize_to_string(el)
    assert_includes(s, "href=\"/x\"")
  end

  def test_serializes_nil_to_empty
    assert_equal("", @serializer.serialize_to_string(nil))
  end

  def test_via_js_bridge
    el = @doc.create_element("b")
    s = @serializer.__js_call__("serializeToString", [el])
    assert_includes(s, "<b")
  end
end
