# frozen_string_literal: true

require_relative "test_helper"

class TestRange < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='p'>Hello, world!</p>")
    @doc = @win.document
    @p = @doc.query_selector("#p")
    # TextNode "Hello, world!"
    @text = @p.first_child
  end

  # --- Boundaries -------------------------------------------------

  def test_default_is_collapsed
    range = @doc.create_range
    assert(range.collapsed?)
  end

  def test_set_start_and_end
    range = @doc.create_range
    range.set_start(@text, 7)
    range.set_end(@text, 12)
    assert_equal("world", range.to_s)
    refute(range.collapsed?)
  end

  def test_collapse_to_start
    range = @doc.create_range
    range.set_start(@text, 7)
    range.set_end(@text, 12)
    range.collapse(true)
    assert(range.collapsed?)
    assert_equal(7, range.end_offset)
  end

  def test_select_node_contents
    range = @doc.create_range
    range.select_node_contents(@p)
    assert_equal("Hello, world!", range.to_s)
  end

  # --- Content extraction ----------------------------------------

  def test_clone_contents_does_not_modify_dom
    range = @doc.create_range
    range.set_start(@text, 7)
    range.set_end(@text, 12)
    fragment = range.clone_contents
    assert_kind_of(Dommy::Fragment, fragment)
    # Original DOM intact
    assert_equal("Hello, world!", @text.data)
  end

  def test_extract_contents_removes_from_dom
    range = @doc.create_range
    range.select_node_contents(@p)
    fragment = range.extract_contents
    assert_kind_of(Dommy::Fragment, fragment)
    # After extraction, p should be empty (text node moved)
    # collapse range
    range.delete_contents
  end

  def test_delete_contents
    range = @doc.create_range
    range.select_node_contents(@p)
    range.delete_contents
    # p should have no children
    assert_equal(0, @p.child_nodes.length)
  end

  def test_surround_contents_wraps_with_element
    win = make_window("<p>before<span>middle</span>after</p>")
    p = win.document.query_selector("p")
    mid = p.query_selector("span")

    range = win.document.create_range
    range.select_node(mid)
    mark = win.document.create_element("mark")
    range.surround_contents(mark)

    assert(win.document.query_selector("mark"))
    assert(win.document.query_selector("mark span"))
  end

  # --- Ordering / containment ------------------------------------

  def test_compare_boundary_points
    a = @doc.create_range
    a.set_start(@text, 0)
    a.set_end(@text, 5)

    b = @doc.create_range
    b.set_start(@text, 3)
    b.set_end(@text, 8)

    # START_TO_START: a.start vs b.start → -1 (a earlier)
    assert_equal(-1, a.compare_boundary_points(Dommy::Range::START_TO_START, b))
    # END_TO_END: a.end vs b.end → -1
    assert_equal(-1, a.compare_boundary_points(Dommy::Range::END_TO_END, b))
  end

  def test_clone_range_is_independent
    range = @doc.create_range
    range.set_start(@text, 0)
    range.set_end(@text, 5)
    other = range.clone_range
    other.set_end(@text, 10)
    # Original unchanged
    assert_equal(5, range.end_offset)
    assert_equal(10, other.end_offset)
  end

  # --- JS bridge -------------------------------------------------

  def test_js_bridge_set_start_and_to_string
    range = @doc.create_range
    range.__js_call__("setStart", [@text, 7])
    range.__js_call__("setEnd", [@text, 12])
    assert_equal("world", range.__js_call__("toString", []))
  end

  def test_js_bridge_collapsed_getter
    range = @doc.create_range
    assert_equal(true, range.__js_get__("collapsed"))
    range.__js_call__("setStart", [@text, 0])
    range.__js_call__("setEnd", [@text, 5])
    assert_equal(false, range.__js_get__("collapsed"))
  end

  # --- Document.createRange -------------------------------------

  def test_document_create_range
    range = @doc.create_range
    assert_kind_of(Dommy::Range, range)
  end

  # --- Layout stub ----------------------------------------------

  def test_bounding_client_rect_is_zero
    range = @doc.create_range
    rect = range.get_bounding_client_rect
    assert_kind_of(Dommy::DOMRect, rect)
    assert_equal(0.0, rect.x)
    assert_equal(0.0, rect.width)
  end
end
