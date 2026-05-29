# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for DocumentType (`<!doctype html>`).
# WPT: dom/nodes/DocumentType-* , dom/nodes/nodeType.html
#
# Dommy exposes a minimal HTML5 doctype: `name` is "html" and the
# legacy `publicId` / `systemId` are empty strings (HTML5 doctypes
# carry no external identifiers).
class TestWPTDocumentType < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doctype = @doc.doctype
  end

  def test_doctype_is_DocumentType
    assert_kind_of(Dommy::DocumentType, @doctype)
  end

  # WPT: document.doctype returns the same node across reads.
  def test_doctype_is_stable
    assert_same(@doctype, @doc.doctype)
  end

  def test_doctype_via_js_bridge
    assert_kind_of(Dommy::DocumentType, @doc.__js_get__("doctype"))
  end

  # WPT: DocumentType.name === "html" for <!doctype html>.
  def test_name_is_html
    assert_equal("html", @doctype.name)
  end

  def test_name_via_js_get
    assert_equal("html", @doctype.__js_get__("name"))
  end

  # WPT: nodeType.html — DOCUMENT_TYPE_NODE === 10.
  def test_nodeType_is_10
    assert_equal(10, @doctype.__js_get__("nodeType"))
  end

  # WPT: DocumentType-publicId / systemId — empty for HTML5.
  def test_publicId_is_empty_string
    assert_equal("", @doctype.__js_get__("publicId"))
  end

  def test_systemId_is_empty_string
    assert_equal("", @doctype.__js_get__("systemId"))
  end
end
