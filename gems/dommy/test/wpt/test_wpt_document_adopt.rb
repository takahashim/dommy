# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Document.adoptNode.
# WPT: dom/nodes/Document-adoptNode.html
# Spec: https://dom.spec.whatwg.org/#dom-document-adoptnode
#
# adoptNode moves a node so its ownerDocument becomes the target.
# Dommy implements this with two paths:
#   - same-document: detach from current parent, return the same wrapper
#   - cross-document: deep-clone into the target document
# The cross-document deep-clone is a Dommy deviation from the WHATWG
# spec, which requires identity preservation. This is documented in
# one of the tests below.
class TestWPTDocumentAdoptSameDoc < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_adopt_node_detaches_from_current_parent
    el = @doc.create_element("div")
    @doc.body.append_child(el)
    assert(el.__dommy_backend_node__.parent)
    @doc.adopt_node(el)
    assert_nil(el.__dommy_backend_node__.parent)
  end

  def test_adopt_node_returns_same_wrapper_for_same_document
    el = @doc.create_element("div")
    @doc.body.append_child(el)
    adopted = @doc.adopt_node(el)
    assert_same(el, adopted)
  end

  def test_adopt_node_on_detached_element_is_idempotent
    el = @doc.create_element("div")
    adopted = @doc.adopt_node(el)
    assert_same(el, adopted)
    assert_nil(el.__dommy_backend_node__.parent)
  end

  def test_adopt_node_returns_nil_for_non_node_input
    assert_nil(@doc.adopt_node("string"))
    assert_nil(@doc.adopt_node(nil))
    assert_nil(@doc.adopt_node(42))
  end
end

class TestWPTDocumentAdoptCrossDoc < Minitest::Test
  include DommyTestHelper

  def setup
    @target_win = make_window
    @target_doc = @target_win.document
    @source_win = make_window
    @source_doc = @source_win.document
  end

  def test_adopt_node_cross_document_preserves_tag_name
    external = @source_doc.create_element("p")
    adopted = @target_doc.adopt_node(external)
    assert_equal("P", adopted.tag_name)
  end

  def test_adopt_node_cross_document_preserves_attributes
    external = @source_doc.create_element("div")
    external.set_attribute("class", "external-thing")
    external.set_attribute("data-id", "42")
    adopted = @target_doc.adopt_node(external)
    assert_equal("external-thing", adopted.get_attribute("class"))
    assert_equal("42", adopted.get_attribute("data-id"))
  end

  def test_adopt_node_cross_document_preserves_text_content
    external = @source_doc.create_element("p")
    external.text_content = "hello world"
    adopted = @target_doc.adopt_node(external)
    assert_equal("hello world", adopted.text_content)
  end

  def test_adopt_node_cross_document_detaches_source
    external = @source_doc.create_element("p")
    @source_doc.body.append_child(external)
    @target_doc.adopt_node(external)
    assert_nil(external.__dommy_backend_node__.parent)
  end

  def test_adopt_node_cross_document_preserves_identity
    # Per WHATWG, adoptNode reuses the exact same node and only
    # changes its ownerDocument. Nokogiri reassigns
    # `node.document` when the node is attached under a host in
    # another document, so Dommy migrates the existing wrapper
    # rather than deep-cloning.
    external = @source_doc.create_element("p")
    adopted = @target_doc.adopt_node(external)
    assert_same(external, adopted)
  end

  def test_adopt_node_cross_document_repoints_owner_document
    external = @source_doc.create_element("p")
    @target_doc.adopt_node(external)
    # After adoption, the wrapper's internal @document points at
    # the target document, and the underlying Nokogiri node is
    # registered with the target document's backend_doc.
    assert_same(@target_doc, external.instance_variable_get(:@document))
    assert_same(@target_doc.backend_doc, external.__dommy_backend_node__.document)
  end
end
