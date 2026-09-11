# frozen_string_literal: true

require_relative "../test_helper"

# Replacing a document's child with a DocumentFragment inserts the fragment's
# CHILDREN, not the fragment. WHATWG "replace" step 9 calls insert, whose step 1
# takes the children out of the fragment — a removal that runs the live range
# and NodeIterator pre-remove steps and queues a childList record on the
# fragment — and whose step 5 shifts this document's ranges by the number of
# children.
#
# Spec: https://dom.spec.whatwg.org/#concept-node-replace
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTDocumentReplaceChildFragment < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.child_nodes.to_a.each { |n| n.remove if n.respond_to?(:remove) }
    @old = @doc.create_element("div")
    @doc.append_child(@old)
    @tail = @doc.create_comment("tail")
    @doc.append_child(@tail)

    @fragment = @doc.create_document_fragment
    @a = @doc.create_comment("a")
    @b = @doc.create_comment("b")
    @fragment.append_child(@a)
    @fragment.append_child(@b)
  end

  def test_the_children_are_inserted_not_the_fragment
    @doc.replace_child(@fragment, @old)

    assert_equal [@a, @b, @tail], @doc.child_nodes.to_a
    assert_empty @fragment.child_nodes.to_a
  end

  # A range inside the fragment sees the children's removal: insert step 1's
  # remove runs the live range pre-remove steps.
  def test_a_range_inside_the_fragment_collapses_onto_it
    range = @doc.create_range
    range.set_start(@a, 1)
    range.set_end(@fragment, 2)

    @doc.replace_child(@fragment, @old)

    assert_same @fragment, range.start_container
    assert_equal 0, range.start_offset
    assert_same @fragment, range.end_container
    assert_equal 0, range.end_offset
  end

  # A range on the document shifts by the number of children, not by one.
  def test_a_range_on_the_document_shifts_by_the_child_count
    range = @doc.create_range
    range.set_start(@doc, 2)
    range.set_end(@doc, 2)

    @doc.replace_child(@fragment, @old)

    # The old child leaves (2 -> 1), then two children arrive before it (-> 3).
    assert_equal 3, range.start_offset
    assert_equal 3, range.end_offset
  end

  def test_the_record_lists_the_children_as_added
    records = []
    mo = Dommy::MutationObserver.new(@win, proc { |rs| records.concat(rs) })
    mo.__js_call__("observe", [@doc, { "childList" => true }])

    @doc.replace_child(@fragment, @old)

    taken = mo.__js_call__("takeRecords", []).to_a
    assert_equal 1, taken.size
    assert_equal [@a, @b], taken.first.__js_get__("addedNodes").to_a
    assert_equal [@old], taken.first.__js_get__("removedNodes").to_a
  end
end
