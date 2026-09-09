# frozen_string_literal: true

require_relative "../test_helper"

# Every DOM operation that takes a node out of its parent — an explicit
# removeChild, the implicit removal a MOVE performs, replaceChildren,
# replaceWith, textContent=, DocumentFragment insertion — has to run the same
# WHATWG "removing steps" before the node is detached, or a live Range /
# NodeIterator anchored in the vacated position is left pointing at a node that
# is no longer in the tree.
#
# WPT: dom/ranges/Range-mutations-appendChild.html,
#      dom/ranges/Range-mutations-insertBefore.html,
#      dom/ranges/Range-mutations-replaceChild.html,
#      dom/ranges/Range-mutations-normalize.html,
#      dom/traversal/NodeIterator-removal.html
# Spec: https://dom.spec.whatwg.org/#concept-node-remove
class TestWPTRangeMoveMutations < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='a'><span id='s'><b id='b'></b></span><i id='i'></i></div><div id='dest'></div>")
    @doc = @win.document
    @a = @doc.get_element_by_id("a")
    @span = @doc.get_element_by_id("s")
    @dest = @doc.get_element_by_id("dest")
    @range = @doc.create_range
  end

  def boundaries
    [@range.start_container, @range.start_offset, @range.end_container, @range.end_offset]
  end

  # A boundary INSIDE the moved subtree follows the removing steps: it lands on
  # the old parent at the index the moved node vacated.
  def test_appendChild_move_relocates_a_boundary_inside_the_moved_subtree
    inner = @doc.get_element_by_id("b")
    @range.set_start(inner, 0)
    @range.set_end(inner, 0)
    @dest.append_child(@span)
    assert_equal([@a, 0, @a, 0], boundaries)
  end

  # A boundary anchored on the OLD PARENT past the moved child shifts down one.
  def test_appendChild_move_decrements_an_old_parent_boundary
    @range.set_start(@a, 2)
    @range.set_end(@a, 2)
    @dest.append_child(@span)
    assert_equal([@a, 1, @a, 1], boundaries)
  end

  # insertBefore moves too, and takes the same path.
  def test_insertBefore_move_runs_the_removing_steps
    @range.set_start(@a, 2)
    @range.set_end(@a, 2)
    @dest.insert_before(@span, nil)
    assert_equal([@a, 1, @a, 1], boundaries)
  end

  # A same-parent move is a removal AND an insertion, in that order. Moving the
  # first child to the end takes a boundary that sat after it from 2 down to 1
  # (removal), and the re-insertion at index 1 does not push it back (the insert
  # step only moves boundaries strictly past the inserted node).
  def test_same_parent_move_applies_removal_then_insertion
    @range.set_start(@a, 2)
    @range.set_end(@a, 2)
    @a.append_child(@span) # <span> goes from index 0 to index 1
    assert_equal([@a, 1, @a, 1], boundaries)

    # The mirror image: moving the OTHER child to the end behaves the same way.
    other = @doc.create_range
    other.set_start(@a, 2)
    @a.append_child(@doc.get_element_by_id("i"))
    assert_equal([@a, 1], [other.start_container, other.start_offset])
  end

  def test_replaceChild_runs_the_removing_steps
    inner = @doc.get_element_by_id("b")
    @range.set_start(inner, 0)
    @range.set_end(inner, 0)
    @a.replace_child(@doc.create_element("em"), @span)
    assert_equal([@a, 0, @a, 0], boundaries)
  end

  def test_replaceWith_runs_the_removing_steps
    inner = @doc.get_element_by_id("b")
    @range.set_start(inner, 0)
    @range.set_end(inner, 0)
    @span.replace_with_nodes(@doc.create_element("em"))
    assert_equal([@a, 0, @a, 0], boundaries)
  end

  def test_replaceChildren_runs_the_removing_steps
    @range.set_start(@doc.get_element_by_id("b"), 0)
    @range.set_end(@a, 2)
    @a.replace_children
    assert_equal([@a, 0, @a, 0], boundaries)
  end

  def test_textContent_assignment_runs_the_removing_steps
    @range.set_start(@doc.get_element_by_id("b"), 0)
    @range.set_end(@doc.get_element_by_id("b"), 0)
    @a.text_content = "gone"
    assert_equal([@a, 0, @a, 0], boundaries)
  end

  def test_outerHTML_assignment_runs_the_removing_steps
    @range.set_start(@doc.get_element_by_id("b"), 0)
    @range.set_end(@doc.get_element_by_id("b"), 0)
    @span.outer_html = "<em></em>"
    assert_equal([@a, 0, @a, 0], boundaries)
  end
end

# A DocumentFragment's children are removed from the fragment when it is
# inserted, so a range anchored in the fragment has to follow the same rules.
# WPT: dom/ranges/Range-mutations-appendChild.html (docfrag cases)
class TestWPTFragmentRangeMutations < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  def fragment_of(*names)
    fragment = @doc.create_document_fragment
    names.each { |n| fragment.append_child(@doc.create_element(n)) }
    fragment
  end

  # Every child is removed in order, so a boundary on the fragment itself walks
  # down to 0 rather than dangling past the (now empty) child list.
  def test_a_boundary_on_the_fragment_collapses_as_its_children_leave
    fragment = fragment_of("a", "b", "i")
    range = @doc.create_range
    range.set_start(fragment, 1)
    range.set_end(fragment, 3)
    @host.append_child(fragment)
    assert_equal([fragment, 0, fragment, 0],
      [range.start_container, range.start_offset, range.end_container, range.end_offset])
  end

  # A boundary deep inside a fragment child moves up to the fragment.
  def test_a_boundary_inside_a_fragment_child_moves_to_the_fragment
    fragment = @doc.create_document_fragment
    child = @doc.create_element("p")
    text = @doc.create_text_node("hello")
    child.append_child(text)
    fragment.append_child(child)
    range = @doc.create_range
    range.set_start(text, 1)
    range.set_end(text, 3)
    @host.append_child(fragment)
    assert_equal([fragment, 0, fragment, 0],
      [range.start_container, range.start_offset, range.end_container, range.end_offset])
  end

  def test_replaceChildren_with_a_fragment_empties_it_the_same_way
    fragment = fragment_of("a", "b")
    range = @doc.create_range
    range.set_start(fragment, 0)
    range.set_end(fragment, 2)
    @host.replace_children(fragment)
    assert_equal([0, 0], [range.start_offset, range.end_offset])
    assert_same(fragment, range.start_container)
  end

  # replaceChild on a fragment removes the old child before inserting, so a
  # boundary inside it lands on the fragment at the vacated index.
  def test_replaceChild_on_a_fragment_runs_the_removing_steps
    fragment = @doc.create_document_fragment
    child = @doc.create_element("a")
    child.append_child(@doc.create_element("x"))
    fragment.append_child(child)
    fragment.append_child(@doc.create_element("b"))
    range = @doc.create_range
    range.set_start(child.first_child, 0)
    range.set_end(fragment, 2)
    fragment.replace_child(@doc.create_element("z"), child)
    assert_same(fragment, range.start_container)
    assert_equal([0, 2], [range.start_offset, range.end_offset])
    assert_equal(%w[z b], fragment.child_nodes.to_a.map(&:local_name))
  end

  def test_insertBefore_with_a_fragment_empties_it_the_same_way
    @host.inner_html = "<u></u>"
    fragment = fragment_of("a", "b")
    range = @doc.create_range
    range.set_start(fragment, 1)
    range.set_end(fragment, 2)
    @host.insert_before(fragment, @host.first_child)
    assert_equal([0, 0], [range.start_offset, range.end_offset])
  end
end

# normalize() merges text runs; the merged-away nodes hand their boundaries to
# the survivor at the offset their data lands at (WHATWG normalize step 6),
# rather than letting the plain removing steps strand them on the parent.
# WPT: dom/ranges/Range-mutations-normalize.html
class TestWPTNormalizeRangeMutations < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='d'></div>")
    @doc = @win.document
    @div = @doc.get_element_by_id("d")
    %w[A BB CCC DDDD].each { |t| @div.append_child(@doc.create_text_node(t)) }
    @nodes = @div.child_nodes.to_a
  end

  def test_boundaries_spanning_merged_nodes_land_in_the_survivor
    range = @doc.create_range
    range.set_start(@nodes[1], 1)  # inside "BB"
    range.set_end(@nodes[3], 2)    # inside "DDDD"
    @div.normalize
    merged = @div.first_child
    assert_equal("ABBCCCDDDD", merged.data)
    assert_same(merged, range.start_container)
    assert_same(merged, range.end_container)
    assert_equal([2, 8], [range.start_offset, range.end_offset])
  end

  # A parent boundary past the whole run is shifted down once per removal, one
  # sibling at a time, and ends up right after the survivor.
  def test_a_parent_boundary_past_the_run_shifts_down_by_each_removal
    @div.append_child(@doc.create_element("b"))
    range = @doc.create_range
    range.set_start(@div, 4) # points at <b>
    range.set_end(@div, 5)
    @div.normalize
    assert_same(@div, range.start_container)
    assert_equal([1, 2], [range.start_offset, range.end_offset])
  end

  # A boundary inside an EMPTY sibling of the run has no data to follow, but
  # still moves to the survivor's join rather than being stranded on the parent.
  def test_a_boundary_in_an_empty_sibling_lands_at_the_join
    div = @doc.create_element("div")
    @doc.body.append_child(div)
    ["A", "", "B"].each { |t| div.append_child(@doc.create_text_node(t)) }
    empty = div.child_nodes[1]
    range = @doc.create_range
    range.set_start(empty, 0)
    range.set_end(empty, 0)
    div.normalize
    merged = div.first_child
    assert_equal("AB", merged.data)
    assert_same(merged, range.start_container)
    assert_equal([1, 1], [range.start_offset, range.end_offset])
  end

  def test_a_parent_boundary_pointing_at_a_merged_node_lands_at_the_join
    range = @doc.create_range
    range.set_start(@div, 2) # points at "CCC"
    range.set_end(@div, 2)
    @div.normalize
    merged = @div.first_child
    assert_same(merged, range.start_container)
    assert_equal([3, 3], [range.start_offset, range.end_offset])
  end
end

# The NodeIterator pre-removing steps run on the same paths, so its
# referenceNode never survives as a detached node.
# WPT: dom/traversal/NodeIterator-removal.html
class TestWPTNodeIteratorRemovalConsistency < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'><a id='a'><b id='b'></b></a><i id='i'></i></div><div id='other'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @other = @doc.get_element_by_id("other")
  end

  # Advance to <b>, the deepest node, so every case below starts with the
  # reference node inside the subtree that is about to move or be removed.
  def iterator_at_b(root = @root)
    iterator = @doc.create_node_iterator(root)
    3.times { iterator.next_node }
    iterator
  end

  def reference_of(iterator)
    [iterator.__js_get__("referenceNode"), iterator.__js_get__("pointerBeforeReferenceNode")]
  end

  def test_appendChild_move_updates_the_reference_node
    iterator = iterator_at_b
    @other.append_child(@doc.get_element_by_id("a"))
    assert_equal([@root, false], reference_of(iterator))
  end

  def test_insertBefore_move_updates_the_reference_node
    iterator = iterator_at_b
    @other.insert_before(@doc.get_element_by_id("a"), nil)
    assert_equal([@root, false], reference_of(iterator))
  end

  def test_replaceChildren_updates_the_reference_node
    iterator = iterator_at_b
    @root.replace_children
    assert_equal([@root, false], reference_of(iterator))
  end

  # replaceWith removes the old child BEFORE inserting the replacements, so the
  # iterator falls back to the parent — not to a node that was not yet in the
  # tree when the removal happened.
  def test_replaceWith_updates_the_reference_node
    iterator = iterator_at_b
    @doc.get_element_by_id("a").replace_with_nodes(@doc.create_element("z"))
    assert_equal([@root, false], reference_of(iterator))
  end

  def test_fragment_insertion_updates_the_reference_node
    fragment = @doc.create_document_fragment
    outer = @doc.create_element("p")
    outer.append_child(@doc.create_element("q"))
    fragment.append_child(outer)
    iterator = iterator_at_b(fragment)
    @root.append_child(fragment)
    assert_equal([fragment, false], reference_of(iterator))
  end
end
