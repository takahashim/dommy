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
end
