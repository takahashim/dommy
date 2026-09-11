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

  # A registration that does not ask for this record type must not shadow
  # another registration of the same observer that does. WHATWG checks the
  # scope and the type together, per registration.
  def test_a_registration_of_the_wrong_type_does_not_shadow_another
    parent = @doc.create_element("div")
    text = @doc.create_text_node("t")
    parent.append_child(text)
    @doc.body.append_child(parent)

    seen = []
    mo = Dommy::MutationObserver.new(@win, proc { |records| seen.concat(records.to_a) })
    # childList on the text node itself: in scope for the mutation below, but
    # not interested in characterData.
    mo.__js_call__("observe", [text, { "childList" => true }])
    # characterData on the parent, with subtree: this is the one that is
    # interested.
    mo.__js_call__("observe", [parent, { "characterData" => true, "subtree" => true }])

    text.data = "u"
    checkpoint

    assert_equal 1, seen.size
    assert_equal "characterData", seen.first.__js_get__("type")
  end

  # A transient registered observer is appended to the removed node's own
  # registered observer list, so it comes after a registration that was already
  # there — even when its observer was constructed first.
  def test_a_transient_comes_after_an_existing_registration_on_that_node
    parent = @doc.create_element("div")
    child = @doc.create_text_node("t")
    parent.append_child(child)
    @doc.body.append_child(parent)

    subtree = observer(:subtree)
    direct = observer(:direct)
    subtree.__js_call__("observe", [parent, { "characterData" => true, "subtree" => true }])
    direct.__js_call__("observe", [child, { "characterData" => true }])

    # The removal gives `child` a transient registration sourced from the
    # subtree observer, appended after `direct`'s registration.
    parent.remove_child(child)
    child.data = "u"
    checkpoint

    assert_equal %i[direct subtree], @order.uniq
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
