# frozen_string_literal: true

require_relative "../test_helper"

# The Selection API method steps. The selection holds at most one range and a
# direction; the direction decides whether the anchor is the range's start
# (forwards) or its end (backwards, or directionless).
#
# Spec: https://w3c.github.io/selection-api/
# WPT:  selection/{addRange,collapse,collapseToStartEnd,extend,getRangeAt,
#       removeRange,selectAllChildren,setBaseAndExtent,type}.* and
#       selection/shadow-dom/tentative/Selection-direction.html
class TestWPTSelectionAPI < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='a'>abc</p><p id='b'>def</p>")
    @doc = @win.document
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
    @ta = @a.first_child
    @tb = @b.first_child
    @sel = @doc.get_selection
  end

  def range(start_node, start_offset, end_node, end_offset)
    r = @doc.create_range
    r.set_start(start_node, start_offset)
    r.set_end(end_node, end_offset)
    r
  end

  def anchor_and_focus
    [@sel.anchor_node, @sel.anchor_offset, @sel.focus_node, @sel.focus_offset]
  end

  # --- the empty selection --------------------------------------------------

  def test_an_empty_selection
    assert_equal(0, @sel.range_count)
    assert_equal("None", @sel.type)
    assert_equal("none", @sel.direction)
    assert_equal([nil, 0, nil, 0], anchor_and_focus)
    assert(@sel.is_collapsed)
    assert_raises(Dommy::DOMException::IndexSizeError) { @sel.get_range_at(0) }
  end

  # --- addRange / removeRange / getRangeAt ------------------------------------

  def test_add_range_keeps_the_range_by_reference_and_runs_forwards
    r = range(@ta, 1, @tb, 2)
    @sel.add_range(r)
    assert_same(r, @sel.get_range_at(0))
    assert_equal([@ta, 1, @tb, 2], anchor_and_focus)
    assert_equal("forward", @sel.direction)

    r.set_start(@ta, 0)
    assert_equal(0, @sel.anchor_offset)
  end

  def test_a_second_add_range_is_ignored
    first = range(@ta, 0, @ta, 1)
    @sel.add_range(first)
    @sel.add_range(range(@tb, 0, @tb, 1))
    assert_same(first, @sel.get_range_at(0))
  end

  def test_add_range_ignores_a_range_in_another_document
    foreign = @doc.implementation.create_html_document("")
    @sel.add_range(foreign.create_range)
    assert_equal(0, @sel.range_count)
  end

  def test_remove_range_only_removes_this_selections_range
    r = range(@ta, 0, @ta, 1)
    @sel.add_range(r)
    assert_raises(Dommy::DOMException::NotFoundError) { @sel.remove_range(range(@ta, 0, @ta, 1)) }
    assert_raises(Dommy::Bridge::TypeError) { @sel.__js_call__("removeRange", [@ta]) }
    @sel.remove_range(r)
    assert_equal(0, @sel.range_count)
  end

  def test_get_range_at_only_answers_index_zero
    @sel.add_range(range(@ta, 0, @ta, 1))
    assert_raises(Dommy::DOMException::IndexSizeError) { @sel.get_range_at(1) }
    assert_raises(Dommy::DOMException::IndexSizeError) { @sel.__js_call__("getRangeAt", [-1]) }
    assert_raises(Dommy::Bridge::TypeError) { @sel.__js_call__("getRangeAt", []) }
  end

  # A range added by reference can be moved out of the document tree; the
  # selection then reports nothing, though it still has the range.
  def test_a_range_that_leaves_the_document_tree_is_not_reported
    r = range(@ta, 0, @ta, 1)
    @sel.add_range(r)
    r.set_start(@doc.create_text_node("elsewhere"), 0)

    assert_equal(0, @sel.range_count)
    assert_equal("None", @sel.type)
    assert_equal([nil, 0, nil, 0], anchor_and_focus)
    assert_raises(Dommy::DOMException::IndexSizeError) { @sel.get_range_at(0) }
  end

  # --- collapse / setPosition / collapseToStart / collapseToEnd ------------------

  def test_collapse_replaces_the_range
    r = range(@ta, 0, @tb, 1)
    @sel.add_range(r)
    @sel.collapse(@tb, 1)
    refute_same(r, @sel.get_range_at(0))
    assert_equal([@tb, 1, @tb, 1], anchor_and_focus)
    assert_equal("Caret", @sel.type)
  end

  def test_collapse_checks_the_point_before_ignoring_a_node_outside_the_document
    doctype = @doc.implementation.create_document_type("x", "", "")
    detached = @doc.create_text_node("xy")
    assert_raises(Dommy::DOMException::InvalidNodeTypeError) { @sel.collapse(doctype, 0) }
    assert_raises(Dommy::DOMException::IndexSizeError) { @sel.collapse(detached, 3) }

    @sel.collapse(@ta, 1)
    @sel.collapse(detached, 1)
    assert_equal([@ta, 1, @ta, 1], anchor_and_focus)
  end

  def test_set_position_is_collapse
    @sel.__js_call__("setPosition", [@ta, 2])
    assert_equal([@ta, 2, @ta, 2], anchor_and_focus)
    @sel.__js_call__("setPosition", [nil])
    assert_equal(0, @sel.range_count)
  end

  def test_collapse_to_start_and_end_make_a_new_range
    assert_raises(Dommy::DOMException::InvalidStateError) { @sel.collapse_to_start }

    r = range(@ta, 1, @tb, 2)
    @sel.add_range(r)
    @sel.collapse_to_end
    assert_equal([@tb, 2, @tb, 2], anchor_and_focus)
    assert_equal([@ta, 1], [r.start_container, r.start_offset])

    @sel.set_base_and_extent(@ta, 1, @tb, 2)
    @sel.collapse_to_start
    assert_equal([@ta, 1, @ta, 1], anchor_and_focus)
  end

  # --- extend -----------------------------------------------------------------

  def test_extend_moves_the_focus_and_keeps_the_anchor
    @sel.collapse(@ta, 1)
    @sel.extend_selection(@tb, 2)
    assert_equal([@ta, 1, @tb, 2], anchor_and_focus)
    assert_equal("forward", @sel.direction)

    @sel.__js_call__("extend", [@ta, 0])
    assert_equal([@ta, 1, @ta, 0], anchor_and_focus)
    assert_equal("backward", @sel.direction)
    r = @sel.get_range_at(0)
    assert_equal([@ta, 0, @ta, 1], [r.start_container, r.start_offset, r.end_container, r.end_offset])
  end

  # Step 1 ignores a node outside the document before step 2 looks for a range.
  def test_extend_ignores_a_node_outside_the_document_even_when_empty
    @sel.extend_selection(@doc.create_text_node("xy"), 1)
    assert_raises(Dommy::DOMException::InvalidStateError) { @sel.extend_selection(@ta, 1) }
  end

  # --- setBaseAndExtent -------------------------------------------------------

  def test_set_base_and_extent_can_run_backwards
    @sel.set_base_and_extent(@tb, 2, @ta, 1)
    assert_equal([@tb, 2, @ta, 1], anchor_and_focus)
    assert_equal("backward", @sel.direction)
    r = @sel.get_range_at(0)
    assert_equal([@ta, 1, @tb, 2], [r.start_container, r.start_offset, r.end_container, r.end_offset])
  end

  def test_set_base_and_extent_checks_offsets_before_ignoring_a_node_outside_the_document
    detached = @doc.create_text_node("xy")
    assert_raises(Dommy::DOMException::IndexSizeError) { @sel.set_base_and_extent(detached, 5, @ta, 0) }
    @sel.set_base_and_extent(detached, 1, @ta, 0)
    assert_equal(0, @sel.range_count)
    assert_raises(Dommy::Bridge::TypeError) { @sel.__js_call__("setBaseAndExtent", [@ta, 0, @ta]) }
  end

  # --- selectAllChildren ------------------------------------------------------

  def test_select_all_children_spans_the_children_not_the_length
    @sel.select_all_children(@ta)
    assert_equal([@ta, 0, @ta, 0], anchor_and_focus)

    @sel.select_all_children(@a)
    assert_equal([@a, 0, @a, 1], anchor_and_focus)
    assert_equal("forward", @sel.direction)
    assert_equal("abc", @sel.to_s)
  end

  def test_select_all_children_rejects_a_doctype_and_ignores_other_trees
    doctype = @doc.implementation.create_document_type("x", "", "")
    assert_raises(Dommy::DOMException::InvalidNodeTypeError) { @sel.select_all_children(doctype) }

    @sel.select_all_children(@a)
    @sel.select_all_children(@doc.create_element("div"))
    assert_equal([@a, 0, @a, 1], anchor_and_focus)
  end

  # --- containsNode / deleteFromDocument ----------------------------------------

  def test_contains_node_wholly_or_partially
    @sel.set_base_and_extent(@ta, 1, @tb, 2)
    refute(@sel.contains_node(@a))
    assert(@sel.contains_node(@a, true))

    @sel.select_all_children(@a)
    assert(@sel.contains_node(@ta))
    refute(@sel.contains_node(@b, true))
    assert(@sel.__js_call__("containsNode", [@ta, Dommy::Bridge::UNDEFINED]))
    refute(@sel.contains_node(@doc.implementation.create_html_document("").body))
  end

  def test_delete_from_document_deletes_the_range_contents
    @sel.set_base_and_extent(@ta, 1, @ta, 3)
    @sel.delete_from_document
    assert_equal("a", @ta.data)
    assert(@sel.is_collapsed)
  end

  # --- getSelection ---------------------------------------------------------------

  def test_a_document_without_a_browsing_context_has_no_selection
    assert_nil(@doc.implementation.create_html_document("").get_selection)
  end

  # --- the bridge ---------------------------------------------------------------

  def test_void_operations_return_undefined_over_the_bridge
    assert_same(Dommy::Bridge::UNDEFINED, @sel.__js_call__("collapse", [@ta, 0]))
    assert_same(Dommy::Bridge::UNDEFINED, @sel.__js_call__("extend", [@ta, 1]))
    assert_equal("forward", @sel.__js_get__("direction"))
  end
end
