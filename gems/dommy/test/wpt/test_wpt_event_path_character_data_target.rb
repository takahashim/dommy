# frozen_string_literal: true

require_relative "../test_helper"

# Dispatch step 5.9.6 appends each ancestor as a plain path item — no
# shadow-adjusted target — when the target's root is a shadow-including inclusive
# ancestor of it. That holds whatever kind of node the target is. A Text,
# Comment or ProcessingInstruction target used to report no root at all, so every
# ancestor was taken for a shadow boundary: its listeners ran AT_TARGET, ran even
# for an event that does not bubble, and saw `event.target` swapped for
# themselves.
#
# Spec: https://dom.spec.whatwg.org/#concept-event-dispatch
# Found by differential testing against a Lean 4 formalization of the standard
# (its fixed scenario event-dispatch-at-character-data-target).
class TestWPTEventPathCharacterDataTarget < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='p'>text<!--note--></p>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
    @seen = []
  end

  def listen(target, label, options = nil)
    target.add_event_listener("x", proc { |e| @seen << [label, e.__js_get__("eventPhase"), e.__js_get__("target")] }, options)
  end

  def dispatch_at(target, bubbles:)
    target.dispatch_event(Dommy::Event.new("x", { "bubbles" => bubbles }))
  end

  def test_ancestors_see_capture_and_bubble_phases_with_the_text_as_target
    text = @p.first_child
    listen(@p, :capture, { "capture" => true })
    listen(@p, :bubble)
    listen(text, :target)
    dispatch_at(text, bubbles: true)

    assert_equal([[:capture, Dommy::Event::CAPTURING_PHASE, text],
                  [:target, Dommy::Event::AT_TARGET, text],
                  [:bubble, Dommy::Event::BUBBLING_PHASE, text]], @seen)
  end

  def test_a_non_bubbling_event_skips_the_ancestors_bubble_listeners
    comment = @p.last_child
    listen(@p, :bubble)
    listen(@doc, :document)
    dispatch_at(comment, bubbles: false)

    assert_equal([], @seen)
  end

  def test_the_document_sees_the_character_data_node_as_target
    text = @p.first_child
    listen(@doc, :document)
    dispatch_at(text, bubbles: true)

    assert_equal([[:document, Dommy::Event::BUBBLING_PHASE, text]], @seen)
  end
end
