# frozen_string_literal: true

require_relative "test_helper"

# Inert content (HTML §6.3): not focusable, not hit by the pointer, not in
# the accessibility tree; and what a pointer press does to the focus.
class TestInertInteraction < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <input id="field">
      <div inert><button id="inert-button">x</button></div>
      <button id="b"><span id="inside">label</span></button>
      <div id="plain">plain</div>
    HTML
    @doc = @win.document
    @clicks = []
    @doc.add_event_listener("click", proc { |e| @clicks << e.__js_get__("target").id })
  end

  def el(id) = @doc.get_element_by_id(id)

  def test_an_inert_button_is_not_focusable
    el("inert-button").focus
    assert_same @doc.body, @doc.active_element
  end

  def test_clicking_an_inert_element_fires_nothing
    Dommy::Interaction::EventSynthesis.click(el("inert-button"))
    assert_empty @clicks
  end

  def test_pressing_inside_a_button_focuses_the_button
    Dommy::Interaction::EventSynthesis.click(el("inside"))
    assert_same el("b"), @doc.active_element
    assert_equal ["inside"], @clicks
  end

  def test_pressing_on_something_unfocusable_blurs
    el("field").focus
    Dommy::Interaction::EventSynthesis.click(el("plain"))
    assert_same @doc.body, @doc.active_element
  end

  def test_inert_subtrees_are_left_out_of_the_accessibility_tree
    tree = Dommy::Internal::AccessibilityTree.build(make_window('<button>A</button><div inert><button>B</button></div>').document)
    assert_equal [{role: "button", name: "A"}], tree.to_h[:children]
  end
end
