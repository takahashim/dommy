# frozen_string_literal: true

require_relative "../test_helper"

# "Queue a mutation record" walks the target's INCLUSIVE ANCESTORS from the
# target upward, and for each of them the registrations on that node. Observers
# are appended to the pending set in that order, and the microtask checkpoint
# invokes their callbacks in that order. So an observer registered on the target
# itself is called before one registered on an ancestor, whichever was
# constructed first.
#
# Dommy notified in observer construction order.
#
# Spec: https://dom.spec.whatwg.org/#queueing-a-mutation-record
#       https://dom.spec.whatwg.org/#notify-mutation-observers
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTMutationObserverOrder < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @order = []
  end

  def observer(label)
    Dommy::MutationObserver.new(@win, proc { |_records| @order << label })
  end

  def checkpoint
    @win.scheduler.perform_microtask_checkpoint
  end

  # The ancestor observer is constructed first, but the target's own
  # registration is reached first.
  def test_the_nearest_registration_is_notified_first
    parent = @doc.create_element("div")
    child = @doc.create_text_node("t")
    parent.append_child(child)
    @doc.body.append_child(parent)

    far = observer(:ancestor)
    near = observer(:target)
    far.__js_call__("observe", [parent, { "characterData" => true, "subtree" => true }])
    near.__js_call__("observe", [child, { "characterData" => true }])

    child.data = "u"
    checkpoint

    assert_equal %i[target ancestor], @order
  end

  # Two registrations on the same node keep construction order.
  def test_two_registrations_on_one_node_keep_their_order
    target = @doc.create_element("div")
    @doc.body.append_child(target)

    first = observer(:first)
    second = observer(:second)
    first.__js_call__("observe", [target, { "childList" => true }])
    second.__js_call__("observe", [target, { "childList" => true }])

    target.append_child(@doc.create_element("span"))
    checkpoint

    assert_equal %i[first second], @order
  end

  # The order follows the records, not the observers: an observer that first
  # sees a record earlier in the task is called first.
  def test_the_pending_set_keeps_insertion_order
    a = @doc.create_element("div")
    b = @doc.create_element("div")
    @doc.body.append_child(a)
    @doc.body.append_child(b)

    on_b = observer(:b)
    on_a = observer(:a)
    on_b.__js_call__("observe", [b, { "childList" => true }])
    on_a.__js_call__("observe", [a, { "childList" => true }])

    a.append_child(@doc.create_element("span"))
    b.append_child(@doc.create_element("span"))
    checkpoint

    assert_equal %i[a b], @order
  end
end
