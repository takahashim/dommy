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
    assert(el.__node__.parent)
    @doc.adopt_node(el)
    assert_nil(el.__node__.parent)
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
    assert_nil(el.__node__.parent)
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
    assert_nil(external.__node__.parent)
  end

  def test_adopt_node_cross_document_returns_new_instance
    # Dommy deviation: WHATWG specifies that adoptNode reuses the
    # exact same node and only changes its ownerDocument. Dommy
    # performs a deep clone into the target document, so the
    # returned wrapper is distinct from the source. Test documents
    # the current behaviour rather than the spec.
    external = @source_doc.create_element("p")
    adopted = @target_doc.adopt_node(external)
    refute_same(external, adopted)
  end
end
