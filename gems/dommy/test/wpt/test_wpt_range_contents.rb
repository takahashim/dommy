# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Range's content algorithms and for live-range boundary
# tracking.
#
# WPT: dom/ranges/Range-cloneContents.html, Range-extractContents.html,
#      Range-surroundContents.html, Range-set.html,
#      Range-mutations-{deleteData,insertData,replaceData,splitText,
#      removeChild,insertBefore}.html
class TestWPTRangeContents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @doc.body.append_child(@host)
  end

  def html_of(fragment)
    fragment.child_nodes.to_a.map { |n| n.respond_to?(:outer_html) ? n.outer_html : n.data }.join
  end

  # A range that reaches only part-way into a node copies only that part.
  def range_over_partial_text
    @host.inner_html = "<b>hello</b> world"
    range = @doc.create_range
    range.set_start(@host.first_child.first_child, 2)
    range.set_end(@host.last_child, 3)
    range
  end

  def test_clone_contents_trims_partially_contained_nodes
    range = range_over_partial_text
    assert_equal("<b>llo</b> wo", html_of(range.clone_contents))
  end

  def test_clone_contents_leaves_the_tree_untouched
    range = range_over_partial_text
    range.clone_contents
    assert_equal("<b>hello</b> world", @host.inner_html)
  end

  def test_clone_contents_matches_to_s
    range = range_over_partial_text
    assert_equal(range.to_s, range.clone_contents.text_content)
  end

  def test_extract_contents_trims_partially_contained_nodes
    range = range_over_partial_text
    assert_equal("<b>llo</b> wo", html_of(range.extract_contents))
  end

  def test_extract_contents_removes_only_the_extracted_part
    range = range_over_partial_text
    range.extract_contents
    assert_equal("<b>he</b>rld", @host.inner_html)
  end

  def test_extract_contents_collapses_the_range
    range = range_over_partial_text
    range.extract_contents
    assert(range.collapsed?)
  end

  def test_extract_contents_moves_fully_contained_nodes
    @host.inner_html = "<a></a><i></i>"
    first = @host.children[0]
    range = @doc.create_range
    range.set_start(@host, 0)
    range.set_end(@host, 1)
    fragment = range.extract_contents
    assert_same(first, fragment.first_child)
    assert_equal("<i></i>", @host.inner_html)
  end

  def test_both_boundaries_in_one_text_node_clone
    @host.inner_html = "<p>hello</p>"
    text = @host.first_child.first_child
    range = @doc.create_range
    range.set_start(text, 1)
    range.set_end(text, 3)
    assert_equal("el", range.clone_contents.text_content)
    assert_equal("<p>hello</p>", @host.inner_html)
  end

  def test_both_boundaries_in_one_text_node_extract
    @host.inner_html = "<p>hello</p>"
    text = @host.first_child.first_child
    range = @doc.create_range
    range.set_start(text, 1)
    range.set_end(text, 3)
    assert_equal("el", range.extract_contents.text_content)
    assert_equal("<p>hlo</p>", @host.inner_html)
  end

  def test_boundaries_in_two_different_elements
    @host.inner_html = "<div><p>abc</p><p>def</p></div>"
    inner = @host.first_child
    range = @doc.create_range
    range.set_start(inner.children[0].first_child, 1)
    range.set_end(inner.children[1].first_child, 2)
    assert_equal("<p>bc</p><p>de</p>", html_of(range.clone_contents))
    assert_equal("<p>bc</p><p>de</p>", html_of(range.extract_contents))
    assert_equal("<div><p>a</p><p>f</p></div>", @host.inner_html)
  end

  def test_collapsed_range_yields_an_empty_fragment
    @host.inner_html = "<p>abc</p>"
    range = @doc.create_range
    range.set_start(@host.first_child.first_child, 1)
    range.set_end(@host.first_child.first_child, 1)
    assert_equal(0, range.clone_contents.child_nodes.length)
    assert_equal(0, range.extract_contents.child_nodes.length)
  end
end

class TestWPTRangeSurroundContents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @doc.body.append_child(@host)
  end

  def text_range(start_offset, end_offset)
    text = @host.first_child.first_child
    range = @doc.create_range
    range.set_start(text, start_offset)
    range.set_end(text, end_offset)
    range
  end

  def test_surround_contents_wraps_the_selected_text
    @host.inner_html = "<p>hello</p>"
    text_range(1, 3).surround_contents(@doc.create_element("b"))
    assert_equal("<p>h<b>el</b>lo</p>", @host.inner_html)
  end

  def test_surround_contents_empties_new_parent_first
    @host.inner_html = "<p>hello</p>"
    wrapper = @doc.create_element("b")
    wrapper.inner_html = "<i>discarded</i>"
    text_range(1, 3).surround_contents(wrapper)
    assert_equal("<p>h<b>el</b>lo</p>", @host.inner_html)
  end

  def test_surround_contents_selects_the_new_parent
    @host.inner_html = "<p>hello</p>"
    range = text_range(1, 3)
    wrapper = @doc.create_element("b")
    range.surround_contents(wrapper)
    assert_same(wrapper, range.start_container.child_nodes[range.start_offset])
    assert_equal(range.start_offset + 1, range.end_offset)
  end

  def test_partially_contained_element_raises_invalid_state_error
    @host.inner_html = "<p>abc</p><p>def</p>"
    range = @doc.create_range
    range.set_start(@host.children[0].first_child, 1)
    range.set_end(@host.children[1].first_child, 2)
    assert_raises(Dommy::DOMException::InvalidStateError) do
      range.surround_contents(@doc.create_element("b"))
    end
  end

  def test_fragment_as_new_parent_raises_invalid_node_type_error
    @host.inner_html = "<p>abc</p>"
    assert_raises(Dommy::DOMException::InvalidNodeTypeError) do
      text_range(1, 2).surround_contents(@doc.create_document_fragment)
    end
  end
end

class TestWPTRangeBoundaryValidation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p>hello</p>")
    @doc = @win.document
    @text = @doc.query_selector("p").first_child
    @range = @doc.create_range
  end

  def test_set_start_past_the_node_length_raises_index_size_error
    assert_raises(Dommy::DOMException::IndexSizeError) { @range.set_start(@text, 9) }
  end

  def test_set_end_past_the_node_length_raises_index_size_error
    assert_raises(Dommy::DOMException::IndexSizeError) { @range.set_end(@text, 9) }
  end

  def test_negative_offset_wraps_to_unsigned_long_and_raises
    assert_raises(Dommy::DOMException::IndexSizeError) { @range.set_start(@text, -1) }
  end

  def test_offset_equal_to_the_length_is_allowed
    @range.set_start(@text, 5)
    assert_equal(5, @range.start_offset)
  end

  def test_doctype_boundary_raises_invalid_node_type_error
    doctype = @doc.doctype
    skip "document has no doctype" unless doctype

    assert_raises(Dommy::DOMException::InvalidNodeTypeError) { @range.set_start(doctype, 0) }
  end

  def test_a_boundary_in_another_tree_carries_the_whole_range
    @range.set_start(@text, 1)
    @range.set_end(@text, 3)
    orphan = @doc.create_element("span")
    @range.set_start(orphan, 0)
    assert(@range.collapsed?)
    assert_same(orphan, @range.end_container)
  end
end

class TestWPTLiveRangeMutations < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @doc.body.append_child(@host)
  end

  def text_range(html, start_offset, end_offset)
    @host.inner_html = html
    text = @host.first_child.first_child
    range = @doc.create_range
    range.set_start(text, start_offset)
    range.set_end(text, end_offset)
    [range, text]
  end

  def test_delete_data_before_the_range_shifts_both_boundaries
    range, text = text_range("<p>abcdef</p>", 3, 5)
    text.delete_data(0, 2)
    assert_equal([1, 3], [range.start_offset, range.end_offset])
  end

  def test_delete_data_inside_the_range_shortens_it
    range, text = text_range("<p>abcdef</p>", 1, 5)
    text.delete_data(1, 2)
    assert_equal([1, 3], [range.start_offset, range.end_offset])
  end

  def test_delete_data_straddling_a_boundary_clamps_it
    range, text = text_range("<p>abcdef</p>", 2, 3)
    text.delete_data(1, 3)
    assert_equal([1, 1], [range.start_offset, range.end_offset])
  end

  def test_delete_data_after_the_range_leaves_it_alone
    range, text = text_range("<p>abcdef</p>", 0, 2)
    text.delete_data(3, 2)
    assert_equal([0, 2], [range.start_offset, range.end_offset])
  end

  def test_insert_data_before_the_end_boundary_extends_the_range
    range, text = text_range("<p>abcdef</p>", 1, 3)
    text.insert_data(1, "foo")
    assert_equal([1, 6], [range.start_offset, range.end_offset])
  end

  def test_replace_data_adjusts_by_the_length_difference
    range, text = text_range("<p>abcdef</p>", 1, 5)
    text.replace_data(1, 2, "XYZW")
    assert_equal([1, 7], [range.start_offset, range.end_offset])
  end

  def test_append_data_leaves_the_range_alone
    range, text = text_range("<p>abcdef</p>", 1, 3)
    text.append_data("ZZ")
    assert_equal([1, 3], [range.start_offset, range.end_offset])
  end

  def test_assigning_data_clamps_boundaries_past_the_new_length
    range, text = text_range("<p>abcdef</p>", 2, 4)
    text.data = "xy"
    assert_equal([0, 0], [range.start_offset, range.end_offset])
  end

  def test_split_text_moves_boundaries_past_the_split_to_the_tail
    range, text = text_range("<p>abcdef</p>", 1, 5)
    tail = text.split_text(2)
    assert_same(text, range.start_container)
    assert_equal(1, range.start_offset)
    assert_same(tail, range.end_container)
    assert_equal(3, range.end_offset)
  end

  def test_removing_a_preceding_sibling_shifts_boundaries_down
    @host.inner_html = "<a></a><b></b><i></i>"
    range = @doc.create_range
    range.set_start(@host, 1)
    range.set_end(@host, 3)
    @host.remove_child(@host.children[0])
    assert_equal([0, 2], [range.start_offset, range.end_offset])
  end

  def test_inserting_a_preceding_sibling_shifts_boundaries_up
    @host.inner_html = "<a></a><b></b><i></i>"
    range = @doc.create_range
    range.set_start(@host, 1)
    range.set_end(@host, 3)
    @host.insert_before(@doc.create_element("u"), @host.children[0])
    assert_equal([2, 4], [range.start_offset, range.end_offset])
  end

  def test_removing_an_ancestor_of_a_boundary_collapses_it_onto_that_position
    @host.inner_html = "<a><x></x></a><b></b>"
    range = @doc.create_range
    range.set_start(@host.children[0].first_child, 0)
    range.set_end(@host, 2)
    @host.remove_child(@host.children[0])
    assert_same(@host, range.start_container)
    assert_equal([0, 1], [range.start_offset, range.end_offset])
  end

  def test_a_range_survives_a_round_trip_through_delete_contents
    @host.inner_html = "<p>abcdef</p>"
    text = @host.first_child.first_child
    range = @doc.create_range
    range.set_start(text, 1)
    range.set_end(text, 4)
    range.delete_contents
    assert(range.collapsed?)
    assert_equal("<p>aef</p>", @host.inner_html)
  end
end
