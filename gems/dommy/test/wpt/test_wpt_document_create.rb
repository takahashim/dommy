# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Document factory methods. Cases distilled
# from corresponding tests in `dom/nodes/` in the
# web-platform-tests repository. Each test points back at the WPT
# file it was adapted from.
class TestWPTDocumentCreate < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- Document.createElement ----
  # WPT: dom/nodes/Document-createElement.html

  def test_createElement_localName_and_tagName
    el = @doc.create_element("div")
    assert_equal("div", el.local_name)
    assert_equal("DIV", el.tag_name)
  end

  def test_createElement_namespaceURI_is_html_namespace
    el = @doc.create_element("div")
    assert_equal("http://www.w3.org/1999/xhtml", el.namespace_uri)
  end

  def test_createElement_nodeType_is_element_node
    el = @doc.create_element("div")
    assert_equal(Dommy::Node::ELEMENT_NODE, el.__js_get__("nodeType"))
  end

  def test_createElement_lowercases_html_tag
    el = @doc.create_element("FOO")
    # HTML5 spec lowercases the tag name; tagName remains uppercase.
    assert_equal("FOO", el.tag_name)
  end

  def test_createElement_returns_new_instance_each_time
    a = @doc.create_element("div")
    b = @doc.create_element("div")
    refute_same(a, b)
  end

  # ---- Document.createTextNode ----
  # WPT: dom/nodes/Document-createTextNode.html

  def test_createTextNode_nodeType_is_text_node
    t = @doc.create_text_node("hello")
    assert_equal(Dommy::Node::TEXT_NODE, t.__js_get__("nodeType"))
  end

  def test_createTextNode_data_matches_argument
    t = @doc.create_text_node("hello")
    assert_equal("hello", t.data)
    assert_equal("hello", t.node_value)
    assert_equal("hello", t.text_content)
  end

  def test_createTextNode_empty_string
    t = @doc.create_text_node("")
    assert_equal("", t.data)
  end

  def test_createTextNode_coerces_to_string
    t = @doc.create_text_node(42)
    assert_equal("42", t.data)
  end

  # ---- Document.createComment ----
  # WPT: dom/nodes/Document-createComment.html

  def test_createComment_nodeType_is_comment_node
    c = @doc.create_comment("note")
    assert_equal(Dommy::Node::COMMENT_NODE, c.__js_get__("nodeType"))
  end

  def test_createComment_data_matches_argument
    c = @doc.create_comment(" some text ")
    assert_equal(" some text ", c.data)
    assert_equal(" some text ", c.node_value)
  end

  def test_createComment_empty
    c = @doc.create_comment("")
    assert_equal("", c.data)
  end

  # ---- Document.createDocumentFragment ----
  # WPT: dom/nodes/DocumentFragment-constructor.html

  def test_createDocumentFragment_nodeType
    f = @doc.create_document_fragment
    assert_equal(Dommy::Node::DOCUMENT_FRAGMENT_NODE, f.__js_get__("nodeType"))
  end

  def test_createDocumentFragment_initially_empty
    f = @doc.create_document_fragment
    assert_equal(0, f.child_element_count)
  end

  def test_createDocumentFragment_independent_instances
    refute_same(@doc.create_document_fragment, @doc.create_document_fragment)
  end

  # ---- Document.createAttribute ----
  # WPT: dom/nodes/Document-createAttribute.html

  def test_createAttribute_returns_attr
    a = @doc.create_attribute("test")
    assert_kind_of(Dommy::Attr, a)
    assert_equal("test", a.name)
  end

  def test_createAttribute_initial_value_empty
    a = @doc.create_attribute("test")
    assert_equal("", a.value)
  end

  def test_createAttribute_lowercases_name
    # HTML attribute names are lowercased per spec.
    a = @doc.create_attribute("TEST")
    assert_equal("test", a.name)
  end

  def test_createAttribute_no_owner_initially
    a = @doc.create_attribute("foo")
    assert_nil(a.owner_element)
  end

  # ---- Document.createElementNS ----
  # WPT: dom/nodes/Document-createElementNS.html

  def test_createElementNS_with_explicit_namespace
    el = @doc.create_element_ns("http://www.w3.org/2000/svg", "svg")
    # Non-HTML-namespace elements preserve case; only an HTML-namespace element
    # in an HTML document upper-cases its tagName.
    assert_equal("svg", el.tag_name)
  end

  def test_createElementNS_nil_namespace
    el = @doc.create_element_ns(nil, "div")
    refute_nil(el)
  end

  def test_createElementNS_empty_qname_throws_InvalidCharacterError
    # Spec: empty qualified name → InvalidCharacterError.
    assert_raises(Dommy::DOMException::InvalidCharacterError) do
      @doc.create_element_ns("any", "")
    end
  end

  # ---- createDocument produces a real XML document ----
  # WPT: dom/nodes/DOMImplementation-createDocument.html and friends. The DOM
  # defines createDocument / `new Document()` as XML documents; Dommy backs them
  # with a Makiri XML document, so CDATA is a real node and names keep their case.

  def xml_document = @doc.implementation.create_document(nil, "root", nil)

  def test_createDocument_createCDATASection_is_cdata_node
    cdata = xml_document.create_cdata_section("hi")
    assert_equal(Dommy::Node::CDATA_SECTION_NODE, cdata.__js_get__("nodeType"))
    assert_equal("hi", cdata.data)
  end

  def test_createDocument_preserves_element_case
    el = xml_document.create_element("FooBar")
    assert_equal("FooBar", el.tag_name)
  end

  # ---- cross-kind adoption (Makiri cross-kind import_node) ----

  def test_adopt_xml_node_into_html_tree
    xml = xml_document
    span = xml.create_element("span")
    span.append_child(xml.create_text_node("from-xml"))
    adopted = @doc.adopt_node(span)
    @doc.body.append_child(adopted)
    assert_includes(@doc.body.inner_html, "from-xml")
  end

  def test_import_html_node_into_xml_document
    div = @doc.create_element("div")
    div.append_child(@doc.create_text_node("from-html"))
    imported = xml_document.import_node(div, true)
    assert_equal(Dommy::Node::ELEMENT_NODE, imported.__js_get__("nodeType"))
  end
end
