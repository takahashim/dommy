# frozen_string_literal: true

require_relative "test_helper"

# A DocumentType as a Document's child and as a Node: it can be replaced by
# the element that would follow it, removed like any child, and has only the
# members of Node and ChildNode. And a CharacterData node knows whether it is
# connected, as every Node does.
class TestDoctypeNode < Minitest::Test
  include DommyTestHelper

  def blank_document_with_only_a_doctype
    doc = make_window.document.implementation.create_html_document("")
    doc.remove_child(doc.document_element)
    doc
  end

  # Replace (unlike pre-insert) refuses an element only when a doctype
  # FOLLOWS the child; the doctype being replaced goes.
  def test_an_element_can_replace_the_only_doctype
    doc = blank_document_with_only_a_doctype
    p = doc.create_element("p")
    doc.replace_child(p, doc.doctype)
    assert_same p, doc.document_element
    assert_nil doc.doctype

    doc = blank_document_with_only_a_doctype
    doc.doctype.replace_with(doc.create_element("p"))
    assert_equal "p", doc.document_element.local_name
  end

  def test_an_element_still_cannot_be_inserted_before_the_doctype
    doc = blank_document_with_only_a_doctype
    assert_raises(Dommy::DOMException::HierarchyRequestError) { doc.insert_before(doc.create_element("p"), doc.doctype) }
  end

  def test_remove_child_returns_the_doctype
    doc = make_window.document.implementation.create_html_document("")
    doctype = doc.doctype
    assert_same doctype, doc.remove_child(doctype)
    assert_nil doc.doctype
  end

  def test_remove_child_of_another_documents_doctype_is_not_found
    doc = make_window.document.implementation.create_html_document("")
    other = make_window.document.implementation.create_html_document("").doctype
    assert_raises(Dommy::DOMException::NotFoundError) { doc.remove_child(other) }
  end

  def test_a_doctype_has_no_element_or_parent_node_members
    doctype = make_window.document.implementation.create_html_document("").doctype
    %w[tagName namespaceURI prefix localName firstElementChild lastElementChild childElementCount children].each do |key|
      assert_equal Dommy::Bridge::ABSENT, doctype.__js_get__(key), key
    end
    assert_nil doctype.__js_get__("textContent")
    assert_equal "html", doctype.__js_get__("name")
  end

  def test_character_data_knows_whether_it_is_connected
    doc = make_window("<p>text</p>").document
    fragment = doc.create_document_fragment
    comment = doc.create_comment("c")
    fragment.append_child(comment)
    pi = doc.create_processing_instruction("pi", "x")
    fragment.append_child(pi)

    refute comment.is_connected?
    assert_equal false, pi.__js_get__("isConnected")
    assert doc.query_selector("p").first_child.is_connected?
    doc.body.append_child(fragment)
    assert comment.__js_get__("isConnected")
  end
end
