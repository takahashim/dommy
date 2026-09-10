# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG ParentNode.moveBefore(node, child) and the "move" primitive under it.
#
# A move is NOT remove + insert: it runs neither the removing steps nor the
# insertion steps, never adopts (step 1 requires the same shadow-including root,
# so the node document cannot change), and carries its own validity checks
# instead of "ensure pre-insertion validity". It does share the live range and
# NodeIterator pre-remove steps and the insert offset shift.
#
# Spec: https://dom.spec.whatwg.org/#dom-parentnode-movebefore
class TestWPTMoveBefore < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @doc.body.append_child(@parent)
    @a = @doc.create_element("i")
    @b = @doc.create_element("b")
    @c = @doc.create_element("u")
    [@a, @b, @c].each { |n| @parent.append_child(n) }
  end

  def test_moves_within_the_same_parent
    @parent.move_before(@c, @a)

    assert_equal [@c, @a, @b], @parent.child_nodes.to_a
  end

  def test_a_null_reference_appends
    @parent.move_before(@a, nil)

    assert_equal [@b, @c, @a], @parent.child_nodes.to_a
  end

  # moveBefore step 2: a reference child that IS the node moves out of the way,
  # so the node lands where it already was.
  def test_moving_a_node_before_itself_is_a_no_op
    @parent.move_before(@b, @b)

    assert_equal [@a, @b, @c], @parent.child_nodes.to_a
  end

  def test_moves_between_parents_in_the_same_tree
    other = @doc.create_element("section")
    @doc.body.append_child(other)
    other.move_before(@b, nil)

    assert_equal [@a, @c], @parent.child_nodes.to_a
    assert_equal [@b], other.child_nodes.to_a
  end

  # Step 1: the same shadow-including root. A node from another document — or a
  # detached one — cannot be moved in, which is what keeps a move from adopting.
  def test_rejects_a_node_from_another_root
    orphan = @doc.create_element("span")

    assert_raises(Dommy::DOMException::HierarchyRequestError) { @parent.move_before(orphan, nil) }

    other_doc = Dommy::Window.new.document

    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @parent.move_before(other_doc.create_element("span"), nil)
    end
  end

  # Step 2.
  def test_rejects_a_cycle
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @parent.move_before(@parent, nil) }
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @a.append_child(@doc.create_element("p")) && @a.move_before(@parent, nil) }
  end

  # Step 3.
  def test_rejects_a_reference_that_is_not_a_child
    outside = @doc.create_element("p")
    @doc.body.append_child(outside)

    assert_raises(Dommy::DOMException::NotFoundError) { @parent.move_before(@a, outside) }
  end

  # Step 4: only an Element or a CharacterData node may be moved.
  def test_rejects_a_non_movable_node_type
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @parent.move_before(@doc, nil) }
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @parent.move_before(@doc.doctype, nil) }
  end

  # Step 5: no Text child of a document.
  def test_document_rejects_a_text_node
    text = @doc.create_text_node("x")
    @parent.append_child(text)

    assert_raises(Dommy::DOMException::HierarchyRequestError) { @doc.move_before(text, nil) }
  end

  # Step 6: the document already has an element child, so no element may be
  # moved in — not even the document element itself, to another slot.
  def test_document_rejects_an_element_while_it_has_one
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @doc.move_before(@a, nil) }
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doc.move_before(@doc.document_element, @doc.doctype)
    end
  end

  def test_document_accepts_a_comment
    comment = @doc.create_comment("c")
    @parent.append_child(comment)
    @doc.move_before(comment, @doc.document_element)

    assert_equal comment, @doc.child_nodes.to_a[1]
  end

  # Steps 10 and 16: the live range pre-remove steps run first, and the insert
  # shift is measured against the tree the removal leaves behind — so a boundary
  # the removal moved onto the parent is not shifted again.
  def test_a_range_inside_the_moved_node_lands_where_the_node_was
    range = @doc.create_range
    range.set_start(@c, 0)
    range.set_end(@c, 0)
    @parent.move_before(@c, @a)

    assert_equal [@c, @a, @b], @parent.child_nodes.to_a
    # The pre-remove steps (step 10) put the boundary at c's old index, 2, and
    # only THEN does step 16 shift it past the reference child a — unlike an
    # insert, whose step 5 runs before the removal.
    assert_equal [@parent, 3, @parent, 3],
                 [range.start_container, range.start_offset, range.end_container, range.end_offset]
  end

  # Step 11: a NodeIterator anchored on the moved node runs the same pre-remove
  # steps a removal would — the pointer is past the reference, so it falls back
  # to the node preceding the one that left.
  def test_an_iterator_on_the_moved_node_runs_the_pre_remove_steps
    it = @doc.create_node_iterator(@parent)
    it.next_node until it.__js_get__("referenceNode") == @c
    @parent.move_before(@c, @a)

    assert_equal @b, it.__js_get__("referenceNode")
  end

  # A move queues one removal record on the old parent and one addition record
  # on the new one (steps 23-24), and no disconnected/connected callbacks.
  def test_queues_a_record_for_each_side
    other = @doc.create_element("section")
    @doc.body.append_child(other)
    records = []
    observer = Dommy::MutationObserver.new(@win, proc { |rs| records.concat(rs) })
    observer.__js_call__("observe", [@doc.body, { "childList" => true, "subtree" => true }])

    other.move_before(@b, nil)
    @win.scheduler.drain_microtasks

    assert_equal 2, records.size
    assert_equal @parent, records[0].__js_get__("target")
    assert_equal [@b], records[0].__js_get__("removedNodes").to_a
    assert_equal other, records[1].__js_get__("target")
    assert_equal [@b], records[1].__js_get__("addedNodes").to_a
  end
end
