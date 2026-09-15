# frozen_string_literal: true

require_relative "../test_helper"

# moveBefore is not remove + insert, and neither are its custom element
# reactions: each custom element among the moved node's shadow-including
# inclusive descendants gets connectedMoveCallback, and one whose definition has
# none gets disconnectedCallback and then connectedCallback instead. Nothing is
# enqueued when the new parent is not connected. Chrome 149 and Firefox 155 do
# the same.
#
# Spec: https://dom.spec.whatwg.org/#concept-node-move (step 19.3)
#       https://html.spec.whatwg.org/multipage/custom-elements.html#enqueue-a-custom-element-callback-reaction
class TestWPTMoveBeforeCustomElementReactions < Minitest::Test
  include DommyTestHelper

  REACTIONS = []

  class Plain < Dommy::HTMLElement
    def connected_callback
      REACTIONS << [id, :connected]
    end

    def disconnected_callback
      REACTIONS << [id, :disconnected]
    end
  end

  class Mover < Plain
    def connected_move_callback
      REACTIONS << [id, :connected_move]
    end
  end

  def setup
    REACTIONS.clear
    @win = make_window("<div id='p1'></div><div id='p2'></div>")
    @doc = @win.document
    @win.custom_elements.define("plain-el", Plain)
    @win.custom_elements.define("mover-el", Mover)
    @p1 = @doc.get_element_by_id("p1")
    @p2 = @doc.get_element_by_id("p2")
  end

  def custom(tag, id)
    el = @doc.create_element(tag)
    el.id = id
    el
  end

  def moved
    REACTIONS.clear
    yield
    REACTIONS.dup
  end

  def test_a_definition_without_connected_move_callback_is_disconnected_then_connected
    plain = custom("plain-el", "plain")
    @p1.append_child(plain)
    assert_equal([%w[plain disconnected], %w[plain connected]].map { |i, r| [i, r.to_sym] },
                 moved { @p2.move_before(plain, nil) })
  end

  def test_a_definition_with_connected_move_callback_gets_only_that
    mover = custom("mover-el", "mover")
    @p1.append_child(mover)
    assert_equal([["mover", :connected_move]], moved { @p2.move_before(mover, nil) })
  end

  def test_every_custom_descendant_reacts_in_shadow_including_tree_order
    outer = custom("mover-el", "outer")
    @p1.append_child(outer)
    shadow = outer.attach_shadow({ "mode" => "open" })
    shadow.append_child(custom("plain-el", "in-shadow"))
    outer.append_child(custom("mover-el", "child"))

    assert_equal([["outer", :connected_move], ["in-shadow", :disconnected], ["in-shadow", :connected],
                  ["child", :connected_move]],
                 moved { @p2.move_before(outer, nil) })
  end

  def test_nothing_reacts_when_the_new_parent_is_not_connected
    detached = @doc.create_element("div")
    a = @doc.create_element("section")
    b = @doc.create_element("section")
    detached.append_child(a)
    detached.append_child(b)
    mover = custom("mover-el", "mover")
    a.append_child(mover)

    assert_equal([], moved { b.move_before(mover, nil) })
  end

  # An ordinary insertBefore still removes and inserts, whatever the definition.
  def test_insert_before_still_disconnects_and_connects
    mover = custom("mover-el", "mover")
    @p1.append_child(mover)
    assert_equal([["mover", :disconnected], ["mover", :connected]], moved { @p2.insert_before(mover, nil) })
  end
end
