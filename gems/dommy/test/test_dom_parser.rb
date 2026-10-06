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

  # `type` is a required WebIDL enum matched exactly: required from script,
  # while the Ruby API keeps its "text/html" default.
  def test_parseFromString_type_is_a_required_exact_enum
    assert_equal("x", @parser.parse_from_string("<p>x</p>").body.text_content)
    assert_raises(Dommy::Bridge::TypeError) { @parser.parse_from_string("<p>", "TEXT/HTML") }
    assert_raises(Dommy::Bridge::TypeError) { @parser.__js_call__("parseFromString", ["<p>"]) }
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
    doc1 = @parser.parse_from_string("<p>a</p>", "text/html")
    doc2 = @parser.parse_from_string("<p>b</p>", "text/html")
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

  # A document that is not well-formed — the empty string included — is a
  # document holding one `parsererror` element, not an exception.
  def test_xml_parse_error_returns_a_parsererror_document
    ["<span>5", "", "<a x:y='1'/>"].each do |src|
      doc = @parser.parse_from_string(src, "image/svg+xml")
      root = doc.document_element
      assert_equal("parsererror", root.local_name, src)
      assert_equal("http://www.mozilla.org/newlayout/xml/parsererror.xml", root.namespace_uri)
      assert_equal(1, doc.child_nodes.length)
      assert_equal("image/svg+xml", doc.content_type)
    end
  end

  # The new document's URL and origin are the creating window's document's.
  def test_parsed_document_takes_the_window_documents_url
    window = Dommy.parse("<p>")
    window.location.__internal_set_url__("https://example.test/dir/page")
    parser = Dommy::DOMParser.new(window)
    %w[text/html text/xml].each do |type|
      doc = parser.parse_from_string("<a href='x'/>", type)
      assert_equal("https://example.test/dir/page", doc.url)
      assert_equal("example.test", doc.domain)
      assert_equal(window.document.origin, doc.origin)
    end
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
