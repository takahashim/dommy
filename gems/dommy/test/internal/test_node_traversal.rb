# frozen_string_literal: true

require_relative "../test_helper"

class TestNodeTraversal < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><div id='middle'><span id='inner'>X</span></div></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer").__dommy_backend_node__
    @middle = @doc.get_element_by_id("middle").__dommy_backend_node__
    @inner = @doc.get_element_by_id("inner").__dommy_backend_node__
  end

  def test_each_ancestor_yields_ancestors_from_closest_to_root
    ancestors = []
    Dommy::Internal::NodeTraversal.each_ancestor(@inner) { |n| ancestors << n }
    assert_includes(ancestors, @middle)
    assert_includes(ancestors, @outer)
    assert_equal(@middle, ancestors.first)
  end

  def test_each_ancestor_stops_before_document
    ancestors = []
    Dommy::Internal::NodeTraversal.each_ancestor(@inner) { |n| ancestors << n }
    refute(ancestors.any? { |n| n.is_a?(Dommy::Backend.document_class) })
  end

  def test_each_ancestor_on_orphan_yields_nothing
    orphan = Dommy::Backend.create_element("p", @doc.nokogiri_doc)
    ancestors = []
    Dommy::Internal::NodeTraversal.each_ancestor(orphan) { |n| ancestors << n }
    assert_empty(ancestors)
  end

  def test_ancestor_of_returns_true_for_direct_parent
    assert(Dommy::Internal::NodeTraversal.ancestor_of?(@middle, @inner))
  end

  def test_ancestor_of_returns_true_for_grandparent
    assert(Dommy::Internal::NodeTraversal.ancestor_of?(@outer, @inner))
  end

  def test_ancestor_of_returns_false_for_self
    refute(Dommy::Internal::NodeTraversal.ancestor_of?(@inner, @inner))
  end

  def test_ancestor_of_returns_false_for_unrelated_node
    other = @doc.create_element("p").__dommy_backend_node__
    refute(Dommy::Internal::NodeTraversal.ancestor_of?(other, @inner))
  end

  def test_find_ancestor_returns_block_result
    result = Dommy::Internal::NodeTraversal.find_ancestor(@inner) do |n|
      n.name == "div" ? "found-#{n["id"]}" : nil
    end

    assert_equal("found-middle", result)
  end

  def test_find_ancestor_returns_nil_when_no_match
    result = Dommy::Internal::NodeTraversal.find_ancestor(@inner) do |_n|
      nil
    end

    assert_nil(result)
  end
end
