# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG remove step 20 appends a transient registered observer to the removed
# node for every subtree registration reachable from the old parent, so a
# subtree observer keeps seeing mutations inside the just-removed subtree until
# the next microtask checkpoint. That step is NOT guarded by suppressObservers —
# only step 21's record is — so it must also run for the removals that queue no
# record: replace all step 3, insert step 4 and replace step 7.
#
# Spec: https://dom.spec.whatwg.org/#concept-node-remove
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTTransientRegisteredObserver < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @observer = Dommy::MutationObserver.new(@win, proc { |_rs| nil })
  end

  def observe(target, options)
    @observer.__js_call__("observe", [target, options])
  end

  def taken
    @observer.__js_call__("takeRecords", [])
  end

  def nodes_of(record, key)
    record.__js_get__(key).to_a
  end

  # replaceChildren removes the existing children with observers suppressed, so
  # no record is queued for that removal — but the transient registration still
  # has to be made, or a later mutation inside the removed subtree is lost.
  def test_replace_children_still_registers_a_transient_observer
    root = @doc.create_element("div")
    kept = @doc.create_element("span")
    inner = @doc.create_comment("c")
    kept.append_child(inner)
    root.append_child(kept)
    @doc.body.append_child(root)
    observe(root, { "childList" => true, "subtree" => true })

    # `kept` leaves root's child list here, and `inner` leaves `kept` as part of
    # the same call — the second removal is observed through the transient.
    root.replace_children(inner)

    records = taken
    assert_equal [inner], nodes_of(records.last, "addedNodes")
    assert(records.any? { |r| r.__js_get__("target") == kept },
           "no record for the mutation inside the removed subtree")
  end

  # The same for a plain removal, which already worked: the transient must not
  # be added twice now that the removal primitive owns the step.
  def test_a_removal_registers_exactly_one_transient_observer
    root = @doc.create_element("div")
    kept = @doc.create_element("span")
    inner = @doc.create_comment("c")
    kept.append_child(inner)
    root.append_child(kept)
    @doc.body.append_child(root)
    observe(root, { "childList" => true, "subtree" => true })

    root.remove_child(kept)
    kept.remove_child(inner)

    records = taken
    inside = records.select { |r| r.__js_get__("target") == kept }
    assert_equal 1, inside.size
    assert_equal [inner], nodes_of(inside.first, "removedNodes")
  end
end
