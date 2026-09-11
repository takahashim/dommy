# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG "insert a node into a parent before a child" runs the live-range offset
# shift at step 5, BEFORE step 7 adopts each node — and adopting removes it from
# wherever it is now. A boundary that one of those removals moves onto the
# parent must therefore NOT be shifted by the insertion that caused it.
#
# Spec: https://dom.spec.whatwg.org/#concept-node-insert (step 5)
#       https://dom.spec.whatwg.org/#concept-node-replace (steps 6-9)
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTLiveRangeInsertOrder < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @doc.body.append_child(@parent)
  end

  def bounds(range)
    [range.start_container, range.start_offset, range.end_container, range.end_offset]
  end

  # Moving the second child in front of the first: the range inside it lands at
  # (parent, 1) from the removal, and step 5 — which ran first, against a
  # boundary that was still inside the node — leaves it there.
  def test_insert_before_does_not_shift_a_boundary_its_own_removal_moved
    a = @doc.create_comment("cc")
    b = @doc.create_text_node("tt")
    @parent.append_child(a)
    @parent.append_child(b)
    range = @doc.create_range
    range.set_start(b, 0)
    range.set_end(b, 2)

    @parent.insert_before(b, a)

    assert_equal [b, a], @parent.child_nodes.to_a
    assert_equal [@parent, 1, @parent, 1], bounds(range)
  end

  # The same through ChildNode#before, which ends in the same pre-insert.
  def test_before_does_not_shift_a_boundary_its_own_removal_moved
    a = @doc.create_comment("cc")
    b = @doc.create_element("span")
    @parent.append_child(a)
    @parent.append_child(b)
    range = @doc.create_range
    range.set_start(b, 0)
    range.set_end(b, 0)

    a.before(b)

    assert_equal [b, a], @parent.child_nodes.to_a
    assert_equal [@parent, 1, @parent, 1], bounds(range)
  end

  # A boundary that is NOT touched by the removal still gets the ordinary step 5
  # shift, so the plain case must keep working.
  def test_inserting_a_fresh_node_still_shifts_later_boundaries
    a = @doc.create_comment("a")
    b = @doc.create_comment("b")
    @parent.append_child(a)
    @parent.append_child(b)
    range = @doc.create_range
    range.set_start(@parent, 1)
    range.set_end(@parent, 2)

    @parent.insert_before(@doc.create_comment("new"), a)

    assert_equal [@parent, 2, @parent, 3], bounds(range)
  end

  # WHATWG pre-insert step 3: when the reference child IS the node being
  # inserted it moves out of the way, so step 5 measures the reference's NEXT
  # sibling. `x.before(x)` therefore shifts a boundary sitting between x and its
  # next sibling, and then the removal shifts it back.
  def test_before_self_uses_the_next_sibling_as_the_reference
    first = @doc.create_comment("0")
    x = @doc.create_comment("1")
    last = @doc.create_comment("2")
    [first, x, last].each { |n| @parent.append_child(n) }
    range = @doc.create_range
    range.set_start(@parent, 2)
    range.set_end(@parent, 2)

    x.before(x)

    assert_equal [first, x, last], @parent.child_nodes.to_a
    assert_equal [@parent, 1, @parent, 1], bounds(range)
  end

  # "Replace" adopts the replacement (step 6, removing it from its old parent),
  # removes the old child (step 7), and only then inserts (step 9) — so step 5
  # sees the tree both removals leave behind.
  def test_replace_child_shifts_against_the_tree_both_removals_leave
    a = @doc.create_text_node("aa")
    b = @doc.create_comment("b")
    c = @doc.create_comment("c")
    [a, b, c].each { |n| @parent.append_child(n) }
    range = @doc.create_range
    range.set_start(c, 1)
    range.set_end(@parent, 3)

    # Adopt c (removes it, start follows to (parent, 2), end 3 -> 2), remove b
    # (both -> 1), then append c: the reference child advanced past c to null,
    # so step 5 shifts nothing.
    @parent.replace_child(c, b)

    assert_equal [a, c], @parent.child_nodes.to_a
    assert_equal [@parent, 1, @parent, 1], bounds(range)
  end

  # A DocumentFragment inserted into the DOCUMENT's own child list must still
  # run insert step 4 — remove the fragment's children, with their removing
  # steps — so a live range inside them follows to the fragment.
  def test_document_append_child_of_a_fragment_runs_the_removing_steps
    frag = @doc.create_document_fragment
    comment = @doc.create_comment("cc")
    frag.append_child(comment)
    range = @doc.create_range
    range.set_start(comment, 0)
    range.set_end(comment, 1)

    @doc.append_child(frag)

    assert_equal @doc, comment.parent_node
    assert_equal [frag, 0, frag, 0], bounds(range)
  end
end
