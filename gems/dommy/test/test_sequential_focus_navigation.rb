# frozen_string_literal: true

require_relative "test_helper"

# HTML §6.6.5 sequential focus navigation (Tab / Shift+Tab from the driver)
# and the :focus-visible heuristics.
class TestSequentialFocusNavigation < Minitest::Test
  include DommyTestHelper

  def setup_page(html)
    @win = make_window(html)
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)
  def sender = Dommy::Interaction::KeySender.new(Dommy::Interaction::FieldInteractor.new(nil, @doc))

  def tab(target = @doc.active_element)
    sender.dispatch(target, :tab)
    @doc.active_element&.id
  end

  def shift_tab(target = @doc.active_element)
    sender.dispatch(target, [:shift, :tab])
    @doc.active_element&.id
  end

  def test_positive_tabindex_first_then_tree_order
    setup_page(<<~HTML)
      <button id="a">a</button>
      <div id="t2" tabindex="2">2</div>
      <input id="i">
      <div id="t1" tabindex="1">1</div>
      <div id="neg" tabindex="-1">-1</div>
      <a id="link" href="#x">x</a>
      <button id="dis" disabled>d</button>
      <div hidden><button id="hidden">h</button></div>
    HTML
    assert_equal %w[t1 t2 a i link], 5.times.map { tab }
    # Past the end, a user agent with no controls of its own wraps around.
    assert_equal "t1", tab
    el("t1").focus
    assert_equal %w[link i a t2], 4.times.map { shift_tab }
  end

  def test_keydown_prevented_tab_does_not_move_focus
    setup_page('<button id="a">a</button><button id="b">b</button>')
    el("a").focus
    @doc.add_event_listener("keydown", ->(e) { e.__js_call__("preventDefault", []) })
    assert_equal "a", tab
  end

  def test_shadow_trees_and_slots_are_navigated_in_place
    setup_page(<<~HTML)
      <button id="before">before</button>
      <div id="host"><button id="slotted" slot="s">slotted</button></div>
      <button id="after">after</button>
    HTML
    root = el("host").attach_shadow("mode" => "open")
    root.inner_html = '<button id="inner1">1</button><slot name="s"></slot><button id="inner2">2</button>'
    ids = 5.times.map do
      tab
      focused = @doc.__internal_focused_element__
      focused.id
    end
    assert_equal %w[before inner1 slotted inner2 after], ids
  end

  def test_a_modal_dialog_keeps_the_focus_inside
    setup_page(<<~HTML)
      <button id="out">out</button>
      <dialog id="d"><button id="d1">1</button><button id="d2">2</button></dialog>
    HTML
    el("d").show_modal
    assert_equal "d1", @doc.active_element.id
    assert_equal %w[d2 d1 d2], 3.times.map { tab }
  end

  def test_popover_contents_follow_their_invoker
    setup_page(<<~HTML)
      <button id="inv" popovertarget="p">open</button>
      <button id="next">next</button>
      <div id="p" popover><button id="in-p">in</button></div>
    HTML
    Dommy::Interaction::EventSynthesis.click(el("inv"))
    assert el("p").matches?(":popover-open")
    assert_equal "inv", @doc.active_element.id
    assert_equal %w[in-p next], 2.times.map { tab }
  end

  def test_tab_from_the_click_starting_point
    setup_page(<<~HTML)
      <button id="a">a</button>
      <p id="text">text</p>
      <button id="b">b</button>
    HTML
    Dommy::Interaction::EventSynthesis.click(el("text"))
    assert_equal "b", tab(@doc.body)
  end

  def test_keyboard_focus_is_visible_and_click_focus_is_not
    setup_page('<button id="a">a</button><button id="b">b</button><input id="i">')
    Dommy::Interaction::EventSynthesis.click(el("a"))
    assert el("a").matches?(":focus")
    refute el("a").matches?(":focus-visible")
    tab
    assert el("b").matches?(":focus-visible")
    # A text field indicates its focus however it got it.
    Dommy::Interaction::EventSynthesis.click(el("i"))
    assert el("i").matches?(":focus-visible")
  end

  def test_script_focus_follows_the_last_input_modality
    setup_page('<button id="a">a</button><button id="b">b</button>')
    el("a").focus
    assert el("a").matches?(":focus-visible"), "script focus with no user input yet is visible"
    Dommy::Interaction::EventSynthesis.click(el("b"))
    refute el("b").matches?(":focus-visible")
    el("a").focus
    refute el("a").matches?(":focus-visible"), "script focus after a click is not"
    el("a").focus("focusVisible" => true)
    assert el("a").matches?(":focus-visible")
    Dommy::Interaction::EventSynthesis.keydown(el("a"), "x", "KeyX")
    el("b").focus
    assert el("b").matches?(":focus-visible"), "script focus after a key press is"
  end
end
