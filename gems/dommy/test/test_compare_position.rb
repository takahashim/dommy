# frozen_string_literal: true

require_relative "test_helper"

class TestComparePosition < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='a'><p id='b'>x</p><p id='c'>y</p></div>")
    @doc = @win.document
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
    @c = @doc.get_element_by_id("c")
  end

  def test_same_node_returns_zero
    assert_equal(0, @a.compare_document_position(@a))
  end

  def test_descendant_contained_by_following
    expected = Dommy::Element::DOCUMENT_POSITION_CONTAINED_BY |
      Dommy::Element::DOCUMENT_POSITION_FOLLOWING
    assert_equal(expected, @a.compare_document_position(@b))
  end

  def test_ancestor_contains_preceding
    expected = Dommy::Element::DOCUMENT_POSITION_CONTAINS |
      Dommy::Element::DOCUMENT_POSITION_PRECEDING
    assert_equal(expected, @b.compare_document_position(@a))
  end

  def test_sibling_following
    expected = Dommy::Element::DOCUMENT_POSITION_FOLLOWING
    assert_equal(expected, @b.compare_document_position(@c))
  end

  def test_sibling_preceding
    expected = Dommy::Element::DOCUMENT_POSITION_PRECEDING
    assert_equal(expected, @c.compare_document_position(@b))
  end

  def test_disconnected_returns_bitmask
    detached = @doc.create_element("div")
    result = @a.compare_document_position(detached)
    assert(result & Dommy::Element::DOCUMENT_POSITION_DISCONNECTED != 0)
  end
end
