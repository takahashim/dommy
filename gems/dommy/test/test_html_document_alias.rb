# frozen_string_literal: true

require_relative "test_helper"

# HTMLDocument, the legacy alias an HTML document reports as its interface, so
# `document.constructor === HTMLDocument` and `document.__proto__ ===
# HTMLDocument.prototype` hold. An XML document stays a plain Document.
class TestHtmlDocumentAlias < Minitest::Test
  def test_html_document_chain
    document = Dommy.parse("<p>x</p>").document
    assert_equal %w[HTMLDocument Document Node EventTarget],
      Dommy::Js::DomInterfaces.chain_for(document)
  end

  def test_xml_document_is_not_an_html_document
    window = Dommy::Window.new
    document = Dommy::DOMParser.new(window).parse_from_string("<r/>", "application/xml")
    assert_equal %w[Document Node EventTarget], Dommy::Js::DomInterfaces.chain_for(document)
  end

  def test_html_document_is_seeded
    assert_includes Dommy::Js::DomInterfaces::BASE_CHAINS, %w[HTMLDocument Document Node EventTarget]
  end

  # createDocument is the one path that yields an XMLDocument; a DOMParser XML
  # result is a plain Document, so the interface rides on the instance.
  def test_create_document_is_an_xml_document
    xml = Dommy.parse("<p>x</p>").document.implementation.create_document(nil, "root", nil)
    assert_equal %w[XMLDocument Document Node EventTarget], Dommy::Js::DomInterfaces.chain_for(xml)
  end

  def test_xml_document_is_seeded
    assert_includes Dommy::Js::DomInterfaces::BASE_CHAINS, %w[XMLDocument Document Node EventTarget]
  end

  def test_clone_of_an_xml_document_stays_an_xml_document
    xml = Dommy.parse("<p>x</p>").document.implementation.create_document(nil, "root", nil)
    assert_equal %w[XMLDocument Document Node EventTarget],
      Dommy::Js::DomInterfaces.chain_for(xml.clone_node(true))
  end

  def test_create_document_requires_namespace_and_qualified_name
    implementation = Dommy.parse("<p>x</p>").document.implementation
    assert_raises(Dommy::Bridge::TypeError) { implementation.__js_call__("createDocument", []) }
    assert_raises(Dommy::Bridge::TypeError) { implementation.__js_call__("createDocument", [""]) }
  end

  def test_create_document_rejects_a_non_document_type_doctype
    implementation = Dommy.parse("<p>x</p>").document.implementation
    assert_raises(Dommy::Bridge::TypeError) { implementation.create_document(nil, nil, false) }
  end

  def test_doctype_conversion_precedes_qualified_name_validation
    implementation = Dommy.parse("<p>x</p>").document.implementation
    assert_raises(Dommy::Bridge::TypeError) { implementation.create_document(nil, "invalid name", false) }
  end
end
