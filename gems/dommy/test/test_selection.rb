# frozen_string_literal: true

require_relative "test_helper"

class TestSelection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='p'>Hello, world!</p>")
    @doc = @win.document
    @p = @doc.query_selector("#p")
    @text = @p.first_child
  end

  def test_get_selection_returns_selection
    sel = @doc.get_selection
    assert_kind_of(Dommy::Selection, sel)
    assert_equal(0, sel.range_count)
  end

  def test_get_selection_returns_same_instance
    assert_same(@doc.get_selection, @doc.get_selection)
  end

  def test_initial_state_is_collapsed
    sel = @doc.get_selection
    assert(sel.is_collapsed)
    assert_equal(0, sel.range_count)
    assert_equal("", sel.to_s)
  end

  def test_add_range_then_to_string
    sel = @doc.get_selection
    range = @doc.create_range
    range.set_start(@text, 7)
    range.set_end(@text, 12)
    sel.add_range(range)
    assert_equal(1, sel.range_count)
    assert_equal("world", sel.to_s)
  end

  def test_collapse_sets_caret
    sel = @doc.get_selection
    sel.collapse(@text, 5)
    assert_equal(1, sel.range_count)
    assert(sel.is_collapsed)
    assert_same(@text, sel.anchor_node)
    assert_equal(5, sel.anchor_offset)
  end

  def test_select_all_children
    sel = @doc.get_selection
    sel.select_all_children(@p)
    assert_equal("Hello, world!", sel.to_s)
  end

  def test_remove_all_ranges
    sel = @doc.get_selection
    sel.select_all_children(@p)
    sel.remove_all_ranges
    assert_equal(0, sel.range_count)
    assert_equal("", sel.to_s)
  end

  def test_anchor_and_focus_match_range_ends
    sel = @doc.get_selection
    range = @doc.create_range
    range.set_start(@text, 1)
    range.set_end(@text, 4)
    sel.add_range(range)
    assert_same(@text, sel.anchor_node)
    assert_equal(1, sel.anchor_offset)
    assert_same(@text, sel.focus_node)
    assert_equal(4, sel.focus_offset)
  end

  def test_js_bridge_get
    sel = @doc.get_selection
    sel.collapse(@text, 5)
    assert_equal(1, sel.__js_get__("rangeCount"))
    assert_equal(true, sel.__js_get__("isCollapsed"))
    assert_equal("Caret", sel.__js_get__("type"))
    sel.select_all_children(@p)
    assert_equal("Range", sel.__js_get__("type"))
  end

  def test_js_bridge_call_select_all_children
    sel = @doc.get_selection
    sel.__js_call__("selectAllChildren", [@p])
    assert_equal("Hello, world!", sel.__js_call__("toString", []))
  end
end
