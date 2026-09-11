# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG puts appendChild / insertBefore / replaceChild / removeChild on Node,
# so every node has them — a leaf (CharacterData, DocumentType) always rejects,
# and a Document applies its own child-list rules. Dommy answered these on the
# JS bridge but not in Ruby, so a Ruby caller got NoMethodError instead of the
# DOMException the standard names.
#
# Spec: https://dom.spec.whatwg.org/#interface-node
class TestWPTNodeMethodsOnEveryNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def leaves
    [
      @doc.create_text_node("t"),
      @doc.create_comment("c"),
      @doc.create_processing_instruction("pi", "d"),
      @doc.implementation.create_document_type("html", "", "")
    ]
  end

  # Pre-insert / replace step 1 rejects a leaf parent with
  # HierarchyRequestError, before the reference child is even looked at.
  def test_a_leaf_rejects_every_insertion
    victim = @doc.create_element("div")
    leaves.each do |leaf|
      assert_raises(Dommy::DOMException::HierarchyRequestError) { leaf.append_child(victim) }
      assert_raises(Dommy::DOMException::HierarchyRequestError) { leaf.insert_before(victim, nil) }
      assert_raises(Dommy::DOMException::HierarchyRequestError) { leaf.replace_child(victim, victim) }
    end
  end

  def test_a_leaf_has_nothing_to_remove
    victim = @doc.create_element("div")
    leaves.each do |leaf|
      assert_raises(Dommy::DOMException::NotFoundError) { leaf.remove_child(victim) }
    end
  end

  # WebIDL coerces the Node argument before any DOM step, so a non-Node is a
  # TypeError rather than a HierarchyRequestError.
  def test_a_leaf_coerces_its_argument_first
    leaves.each do |leaf|
      assert_raises(Dommy::Bridge::TypeError) { leaf.append_child(nil) }
      assert_raises(Dommy::Bridge::TypeError) { leaf.remove_child("not a node") }
    end
  end

  # Element gains WHATWG's own name for the ChildNode method it had as
  # `replace_with_nodes`.
  def test_element_replace_with
    a = @doc.create_element("i")
    @doc.body.append_child(a)
    b = @doc.create_element("b")
    a.replace_with(b)

    assert_equal [b], @doc.body.child_nodes.to_a
  end

  # Document's Node / ParentNode mutators under their standard names.
  def test_document_insert_before_and_remove_child
    comment = @doc.create_comment("c")
    @doc.insert_before(comment, @doc.document_element)

    assert_equal comment, @doc.child_nodes.to_a[1]

    @doc.remove_child(comment)

    refute_includes @doc.child_nodes.to_a, comment
  end

  def test_document_replace_child_swaps_the_document_element
    replacement = @doc.create_element("div")
    @doc.replace_child(replacement, @doc.document_element)

    assert_equal [Dommy::DocumentType, Dommy::HTMLDivElement], @doc.child_nodes.to_a.map(&:class)
  end

  # replaceChildren removes the current children first, so its validity check
  # disregards them (whatwg/dom#1045): a second element is fine here even though
  # the document already has one.
  def test_document_replace_children_disregards_the_current_children
    replacement = @doc.create_element("div")
    @doc.replace_children(replacement)

    assert_equal [replacement], @doc.child_nodes.to_a
  end

  def test_document_replace_children_still_rejects_two_elements
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doc.replace_children(@doc.create_element("div"), @doc.create_element("p"))
    end
  end

  # "Ensure pre-insertion validity" step 2 — a document is its own inclusive
  # ancestor — comes before step 3's NotFoundError on the reference child.
  def test_document_rejects_inserting_itself_before_the_parentage_check
    orphan = @doc.create_comment("c")

    assert_raises(Dommy::DOMException::HierarchyRequestError) { @doc.replace_child(@doc, orphan) }
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @doc.insert_before(@doc, orphan) }
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @doc.append_child(@doc) }
  end
end
