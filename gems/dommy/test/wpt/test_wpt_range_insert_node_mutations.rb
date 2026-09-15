# frozen_string_literal: true

require_relative "../test_helper"

# Range.insertNode() removes a node that already has a parent (step 9) and only
# then pre-inserts it (step 12). Everything observable about the move — other
# live ranges, MutationRecords, custom element reactions — must therefore come
# out as `node.remove()` followed by `parent.insertBefore(node, reference)`.
#
# That is NOT always what a plain `parent.insertBefore(node, reference)` gives.
# There, insert steps 5-6 (the live range shift and the record's
# previousSibling) are read before adopt removes the node; in insertNode the
# removal has already happened. The record test below pins the one place the
# two differ.
#
# Spec: https://dom.spec.whatwg.org/#concept-range-insert
#       https://dom.spec.whatwg.org/#concept-node-insert
class TestWPTRangeInsertNodeMutations < Minitest::Test
  include DommyTestHelper

  class ReactionElement < Dommy::HTMLElement
    def connected_callback
      reactions << :connected
    end

    def disconnected_callback
      reactions << :disconnected
    end

    def reactions
      @reactions ||= []
    end
  end

  def setup
    @win = make_window
    @doc = @win.document
    @observer = Dommy::MutationObserver.new(@win, proc { |_records| nil })
  end

  # A fresh <div> in the body holding <a>, <b>, <i>.
  def build_tree
    parent = @doc.create_element("div")
    parent.inner_html = "<a></a><b></b><i></i>"
    @doc.body.append_child(parent)
    [parent, *parent.child_nodes.to_a]
  end

  def collapsed_range_at(container, offset)
    range = @doc.create_range
    range.set_start(container, offset)
    range
  end

  def bounds(range)
    [range.start_container, range.start_offset, range.end_container, range.end_offset]
  end

  def records_of(target)
    @observer.__js_call__("observe", [target, { "childList" => true }])
    yield
    @observer.__js_call__("takeRecords", []).map do |r|
      [r.__js_get__("removedNodes").to_a, r.__js_get__("addedNodes").to_a,
       r.__js_get__("previousSibling"), r.__js_get__("nextSibling")]
    end
  end

  # --- another live range ------------------------------------------------

  # Moving <a> in front of <i> with a range collapsed at (div, 2): a second range
  # at (div, 3) first drops to 2 when <a> is removed, then rises back to 3 when
  # <a> is inserted before <i>, which by then sits at index 1.
  def test_another_live_range_follows_the_remove_then_the_insert
    parent, a, _b, _i = build_tree
    other = collapsed_range_at(parent, 3)
    range = collapsed_range_at(parent, 2)
    range.insert_node(a)

    assert_equal(%w[b a i], parent.child_nodes.to_a.map(&:local_name))
    assert_equal([parent, 1, parent, 2], bounds(range))
    assert_equal([parent, 3, parent, 3], bounds(other))

    baseline_parent, baseline_a, _, baseline_i = build_tree
    baseline_other = collapsed_range_at(baseline_parent, 3)
    baseline_a.remove
    baseline_parent.insert_before(baseline_a, baseline_i)
    assert_equal([baseline_parent, 3, baseline_parent, 3], bounds(baseline_other))
  end

  # A boundary inside the moved node goes to the parent at its old index when the
  # node is removed, and the insertion further along does not move it again.
  def test_a_live_range_inside_the_moved_node_is_adjusted_once
    parent, a, _b, _i = build_tree
    inside = collapsed_range_at(a, 0)
    collapsed_range_at(parent, 2).insert_node(a)

    assert_equal([parent, 0, parent, 0], bounds(inside))
  end

  # --- MutationRecords ----------------------------------------------------

  # Moving <b> in front of <i>: one removal record, then one addition record,
  # each with the siblings of its own moment. After the removal <b>'s old
  # neighbour <a> is what precedes the insertion point.
  def test_moving_a_sibling_queues_a_removal_then_an_addition
    parent, a, b, i = build_tree
    records = records_of(parent) { collapsed_range_at(parent, 2).insert_node(b) }
    assert_equal([[[b], [], a, i],
                  [[], [b], a, i]], records)

    baseline_parent, baseline_a, baseline_b, baseline_i = build_tree
    baseline = records_of(baseline_parent) do
      baseline_b.remove
      baseline_parent.insert_before(baseline_b, baseline_i)
    end
    assert_equal([[[baseline_b], [], baseline_a, baseline_i],
                  [[], [baseline_b], baseline_a, baseline_i]], baseline)
  end

  # The plain insertBefore of the same move reads previousSibling before adopt
  # removes <b>, so it reports <b> itself — the difference insertNode's own
  # step 9 is there to produce.
  def test_a_plain_insert_before_of_the_same_move_reports_the_node_as_previous_sibling
    parent, a, b, i = build_tree
    records = records_of(parent) { parent.insert_before(b, i) }
    assert_equal([[[b], [], a, i],
                  [[], [b], b, i]], records)
  end

  # A node moved in from another parent queues its removal on the old parent
  # before the addition on the new one.
  def test_moving_from_another_parent_orders_removal_before_addition
    parent, a, _b, _i = build_tree
    other_parent = @doc.create_element("section")
    moved = @doc.create_element("u")
    other_parent.append_child(moved)
    @doc.body.append_child(other_parent)
    @observer.__js_call__("observe", [other_parent, { "childList" => true }])
    records = records_of(parent) { collapsed_range_at(parent, 1).insert_node(moved) }

    assert_equal([[[moved], [], nil, nil],
                  [[], [moved], a, parent.child_nodes.to_a[2]]], records)
  end

  # --- custom element reactions ---------------------------------------------

  def test_a_moved_custom_element_is_disconnected_then_connected_like_insert_before
    @win.custom_elements.define("range-move-el", ReactionElement)
    parent, _a, _b, i = build_tree
    moved = @doc.create_element("range-move-el")
    parent.insert_before(moved, parent.first_child)
    moved.reactions.clear

    collapsed_range_at(parent, 3).insert_node(moved)
    assert_equal([:disconnected, :connected], moved.reactions)
    assert_same(i, moved.next_sibling)

    via_insert_before = @doc.create_element("range-move-el")
    parent.insert_before(via_insert_before, parent.first_child)
    via_insert_before.reactions.clear
    parent.insert_before(via_insert_before, i)
    assert_equal(moved.reactions, via_insert_before.reactions)
  end
end
