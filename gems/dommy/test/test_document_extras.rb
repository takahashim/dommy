# frozen_string_literal: true

require_relative "test_helper"

class TestDocumentExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<header><h1>Title</h1></header><main><p name='msg'>hi</p></main>")
    @doc = @win.document
  end

  def test_head_returns_head_element
    head = @doc.head
    refute_nil(head)
    assert_equal("HEAD", head.tag_name)
  end

  def test_doctype_returns_html_doctype
    dt = @doc.doctype
    refute_nil(dt)
    assert_equal("html", dt.__js_get__("name"))
    assert_equal(10, dt.__js_get__("nodeType"))
  end

  def test_cookie_round_trip
    @doc.cookie = "session=abc"
    @doc.cookie = "theme=dark; Path=/; Expires=Wed"
    assert_equal("session=abc; theme=dark", @doc.cookie)
  end

  def test_cookie_initially_empty
    assert_equal("", @doc.cookie)
  end

  def test_create_element_ns
    el = @doc.create_element_ns("http://www.w3.org/2000/svg", "svg")
    refute_nil(el)
    # SVG (non-HTML namespace) preserves case — tagName is "svg", not "SVG".
    assert_equal("svg", el.tag_name)
  end

  def test_get_elements_by_tag_name
    h1s = @doc.get_elements_by_tag_name("h1")
    assert_equal(1, h1s.size)
    assert_equal("H1", h1s.first.tag_name)
  end

  def test_get_elements_by_tag_name_star
    all = @doc.get_elements_by_tag_name("*")
    assert_operator(all.size, :>=, 4)
  end

  def test_get_elements_by_name
    list = @doc.get_elements_by_name("msg")
    assert_equal(1, list.size)
    assert_equal("P", list.first.tag_name)
  end

  def test_write_appends_to_body
    before = @doc.body.children.size
    @doc.write("<div id='written'>w</div>")
    assert_equal(before + 1, @doc.body.children.size)
    assert_equal("written", @doc.body.children[-1].id)
  end

  def test_open_close_are_noop
    assert_nil(@doc.open)
    assert_nil(@doc.close)
  end

  def test_node_type_constant
    assert_equal(9, @doc.__js_get__("nodeType"))
  end
end

# The document's WebIDL named getter (document.someName → named element).
class TestDocumentNamedGetter < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window(
      "<form name='f1'></form><img name='pic'><iframe name='frame'></iframe>" \
      "<img name='dup'><img name='dup'><img id='byid' name='hasname'>"
    ).document
  end

  def test_single_named_element_returns_the_element
    assert_instance_of Dommy::HTMLFormElement, @doc.__js_get__("f1")
    assert_instance_of Dommy::HTMLImageElement, @doc.__js_get__("pic")
  end

  def test_multiple_named_elements_return_a_collection
    coll = @doc.__js_get__("dup")
    assert_instance_of Dommy::HTMLCollection, coll
    assert_equal 2, coll.length
  end

  def test_img_exposed_by_id_when_it_also_has_a_name
    assert_instance_of Dommy::HTMLImageElement, @doc.__js_get__("byid")
  end

  def test_unknown_name_is_absent
    assert_equal Dommy::Bridge::ABSENT, @doc.__js_get__("nope")
  end

  def test_supported_property_names
    names = @doc.__js_named_props__
    assert_includes names, "f1"
    assert_includes names, "frame"
    assert_includes names, "byid"
    refute_includes names, "nope"
  end
end

# createElementNS with names an XML backend rejects but DOM permits (via
# Makiri's create_loose_dom_element), and error mapping for invalid names.
class TestCreateElementNSLooseNames < Minitest::Test
  include DommyTestHelper

  def xml_doc
    Dommy::DOMParser.new.parse_from_string(
      "<root xmlns='urn:x'/>", "application/xml"
    )
  end

  def test_leading_invalid_char_raises_invalid_character
    assert_raises(Dommy::DOMException::InvalidCharacterError) do
      xml_doc.__js_call__("createElementNS", [nil, "}foo"])
    end
  end

  def test_valid_prefixed_name_preserves_case_and_prefix
    el = xml_doc.__js_call__("createElementNS", ["urn:x", "ns:MyTag"])
    assert_equal "MyTag", el.__js_get__("localName")
    assert_equal "ns", el.__js_get__("prefix")
  end

  # DOM validates the qualified name against the Name production only, so a
  # prefix an XML backend cannot spell as an `xmlns:` attribute is still a valid
  # element — it just gets no namespace declaration written.
  # WPT: dom/nodes/Document-createElementNS.html
  def test_a_prefix_the_backend_cannot_declare_still_creates_the_element
    ["0:a", ";:a"].each do |qualified|
      el = xml_doc.__js_call__("createElementNS", ["http://example.com/", qualified])
      assert_equal("a", el.__js_get__("localName"), qualified)
      assert_equal(qualified.split(":").first, el.__js_get__("prefix"), qualified)
      assert_equal("http://example.com/", el.__js_get__("namespaceURI"), qualified)
    end
  end
end

# createElement validates against the XML *Name* production, which is looser
# than the QName an XML backend insists on.
# WPT: dom/nodes/Document-createElement.html
class TestCreateElementLooseNames < Minitest::Test
  include DommyTestHelper

  def xml_doc
    Dommy::DOMParser.new.parse_from_string("<root/>", "text/xml")
  end

  def xhtml_doc
    Dommy::DOMParser.new.parse_from_string(
      "<html xmlns='http://www.w3.org/1999/xhtml'><body/></html>", "application/xhtml+xml"
    )
  end

  # Colons make a name a poor QName but a perfectly good Name, and a combining
  # char or a brace is fine anywhere but the first position.
  NAMES = [":", ":foo", "foo:", "f:o:o", "f::oo", "f::oo:", "foo:0", "xmlns:foo", "f}oo", "foo}"].freeze

  def test_an_xml_document_accepts_them_verbatim
    doc = xml_doc
    NAMES.each do |name|
      el = doc.create_element(name)
      assert_equal(name, el.local_name, name)
      assert_equal(name, el.tag_name, name)
      assert_nil(el.namespace_uri, name)
      assert_nil(el.__js_get__("prefix"), name)
    end
  end

  def test_an_xhtml_document_puts_them_in_the_html_namespace
    doc = xhtml_doc
    NAMES.each do |name|
      el = doc.create_element(name)
      assert_equal(name, el.local_name, name)
      assert_equal("http://www.w3.org/1999/xhtml", el.namespace_uri, name)
    end
  end

  def test_a_name_that_is_not_a_name_at_all_still_raises
    doc = xml_doc
    ["", "1foo", "fo o", "}foo", "<foo", "foo>", "-foo", ".foo"].each do |name|
      assert_raises(Dommy::DOMException::InvalidCharacterError, name) { doc.create_element(name) }
    end
  end
end

# A Document's nodeValue and textContent are null (DOM), not concatenated text.
class TestDocumentNodeValueTextContent < Minitest::Test
  include DommyTestHelper

  def test_document_nodevalue_and_textcontent_are_null
    doc = make_window("<p>hi</p>").document
    assert_nil doc.__js_get__("nodeValue")
    assert_nil doc.__js_get__("textContent")
  end
end

# The selector index walks the backend element tree; the XML backend has no
# `first_element_child` / `next_element` sibling walk, so a query on an XML
# document used to raise instead of matching.
class TestQuerySelectorOnXmlDocument < Minitest::Test
  include DommyTestHelper

  def xml_doc
    Dommy::DOMParser.new.parse_from_string(
      "<root><a id='x'/><b class='c'><a/></b></root>", "text/xml"
    )
  end

  def test_a_type_selector_matches
    assert_equal(2, xml_doc.query_selector_all("a").to_a.size)
  end

  def test_an_id_selector_matches
    assert_equal("a", xml_doc.query_selector("#x").tag_name)
  end

  def test_a_class_selector_matches
    assert_equal("b", xml_doc.query_selector(".c").tag_name)
  end

  def test_a_descendant_selector_matches
    assert_equal(1, xml_doc.query_selector_all("b a").to_a.size)
  end
end
