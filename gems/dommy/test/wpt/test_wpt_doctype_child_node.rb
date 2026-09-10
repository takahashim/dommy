# frozen_string_literal: true

require_relative "../test_helper"

# A DocumentType is a ChildNode of the document, so its before / after /
# replaceWith are ordinary pre-inserts (and a replace) into the document — with
# the document's own ensure-pre-insertion-validity and the live-range insert
# steps. Dommy had a doctype-specific path that ran neither and picked its
# insertion point by heuristic; createDocumentType also handed back a wrapper it
# never registered, so the doctype reached through the tree was a different
# object.
#
# Spec: https://dom.spec.whatwg.org/#interface-documenttype
class TestWPTDoctypeChildNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doctype = @doc.doctype
  end

  # createDocumentType's wrapper must be the same object the tree hands back.
  def test_created_doctype_keeps_its_identity_in_the_tree
    doc = Dommy::Document.new
    doc.child_nodes.to_a.each { |n| n.remove if n.respond_to?(:remove) }
    made = doc.implementation.create_document_type("html", "", "")
    doc.append_child(made)

    assert_same made, doc.child_nodes.to_a.first
    assert_same made, doc.doctype
  end

  def test_before_inserts_ahead_of_the_doctype
    comment = @doc.create_comment("c")
    @doctype.before(comment)

    assert_equal [comment, @doctype, @doc.document_element], @doc.child_nodes.to_a
  end

  def test_after_inserts_between_the_doctype_and_the_document_element
    comment = @doc.create_comment("c")
    @doctype.after(comment)

    assert_equal [@doctype, comment, @doc.document_element], @doc.child_nodes.to_a
  end

  # Step 6: a Text node may not be a child of a document, whichever side.
  def test_before_and_after_reject_a_text_node
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doctype.before(@doc.create_text_node("x"))
    end
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doctype.after(@doc.create_text_node("x"))
    end
  end

  # Step 6: the document already has an element child, and replace only
  # disregards the child being replaced (the doctype), not that element.
  def test_replace_with_rejects_a_second_element
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doctype.replace_with(@doc.create_element("div"))
    end
    assert_equal [@doctype, @doc.document_element], @doc.child_nodes.to_a
  end

  # An element that is ALREADY the document element is still an element child
  # the count sees, so moving it onto the doctype's slot is rejected too.
  def test_replace_with_rejects_the_document_element_itself
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doctype.replace_with(@doc.document_element)
    end
  end

  def test_replace_with_accepts_a_comment
    comment = @doc.create_comment("c")
    @doctype.replace_with(comment)

    assert_equal [comment, @doc.document_element], @doc.child_nodes.to_a
    assert_nil @doc.doctype
  end

  # The live-range insert steps run for the document's child list too.
  def test_before_shifts_a_live_range_on_the_document
    range = @doc.create_range
    range.set_start(@doc, 1)
    range.set_end(@doc, 2)
    @doctype.before(@doc.create_comment("c"))

    assert_equal [@doc, 2, @doc, 3], [range.start_container, range.start_offset,
                                      range.end_container, range.end_offset]
  end
end
