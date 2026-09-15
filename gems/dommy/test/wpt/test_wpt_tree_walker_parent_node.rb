# frozen_string_literal: true

require_relative "../test_helper"

# TreeWalker.parentNode() climbs from current until it meets the root, and looks
# for nothing else on the way: not whether current can still reach the root. A
# current that was removed from under the root climbs the detached subtree it now
# sits in, and stops only when that subtree runs out of parents.
#
# Spec: https://dom.spec.whatwg.org/#dom-treewalker-parentnode
# Found by differential testing against a Lean 4 formalization of the standard
# (its fixed scenario walker-parent-node-leaves-root).
class TestWPTTreeWalkerParentNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'><section><p>ab</p></section></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @section = @root.first_child
    @p = @section.first_child
    @walker = @doc.create_tree_walker(@root)
  end

  def test_parent_node_stops_at_the_root
    @walker.current_node = @p
    assert_same(@section, @walker.parent_node)
    assert_same(@root, @walker.parent_node)
    assert_nil(@walker.parent_node)
    assert_same(@root, @walker.current_node)
  end

  def test_parent_node_climbs_a_subtree_removed_from_under_the_root
    @walker.current_node = @p
    @root.remove_child(@section)

    assert_same(@section, @walker.parent_node)
    assert_same(@section, @walker.current_node)
    # The detached subtree has no parent above section, so the climb ends there
    # without ever meeting the root.
    assert_nil(@walker.parent_node)
    assert_same(@section, @walker.current_node)
  end

  def test_parent_node_skips_rejected_ancestors
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ALL,
                                     proc { |node| node.equal?(@section) ? Dommy::NodeFilter::FILTER_SKIP : Dommy::NodeFilter::FILTER_ACCEPT })
    walker.current_node = @p
    assert_same(@root, walker.parent_node)
  end
end
