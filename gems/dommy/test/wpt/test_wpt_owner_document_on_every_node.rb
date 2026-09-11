# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG puts `ownerDocument` on Node, so every node exposes it: null for a
# Document, the node's node document otherwise. Dommy defined it on Element
# and Attr only, so a Ruby caller got NoMethodError from Text, Comment,
# ProcessingInstruction, CDATASection, DocumentFragment and DocumentType.
#
# Spec: https://dom.spec.whatwg.org/#dom-node-ownerdocument
class TestWPTOwnerDocumentOnEveryNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def nodes
    {
      "element" => @doc.create_element("div"),
      "text" => @doc.create_text_node("t"),
      "comment" => @doc.create_comment("c"),
      "processingInstruction" => @doc.create_processing_instruction("pi", "d"),
      "documentFragment" => @doc.create_document_fragment,
      "documentType" => @doc.implementation.create_document_type("html", "", "")
    }
  end

  def test_every_node_reports_its_node_document
    nodes.each do |label, node|
      assert_respond_to node, :owner_document, "#{label} has no ownerDocument"
      assert_equal @doc, node.owner_document, "#{label} reports the wrong node document"
    end
  end

  def test_document_reports_null
    assert_nil @doc.owner_document
  end

  # The node document survives being put into the tree.
  def test_attached_node_keeps_its_node_document
    el = @doc.create_element("div")
    text = @doc.create_text_node("t")
    el.append_child(text)
    @doc.body.append_child(el)

    assert_equal @doc, text.owner_document
    assert_equal @doc, el.owner_document
  end

  # A CDATASection only exists in an XML document.
  def test_cdata_section_reports_its_node_document
    xml = Dommy::DOMParser.new.parse_from_string("<root/>", "application/xml")
    cdata = xml.create_cdata_section("x")

    assert_equal xml, cdata.owner_document
  end
end
