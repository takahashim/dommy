# frozen_string_literal: true

require_relative "test_helper"

# HTML §6.4 user activation: the driver's input is trusted, its activation
# triggering events activate the window, and activation-gated APIs read and
# consume that.
class TestUserActivation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <button id="b">x</button>
      <input id="date" type="date">
      <select id="s"><option>a</option></select>
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)
  def synth = Dommy::Interaction::EventSynthesis

  def test_a_window_starts_without_activation
    refute @win.__internal_sticky_activation__?
    refute @win.__internal_transient_activation__?
    refute @win.navigator.__js_get__("userActivation").has_been_active
  end

  def test_a_click_activates_the_window
    synth.click(el("b"))
    activation = @win.navigator.__js_get__("userActivation")
    assert activation.has_been_active
    assert activation.is_active
  end

  def test_transient_activation_expires_but_sticky_activation_stays
    synth.click(el("b"))
    @win.scheduler.advance_time(Dommy::Internal::UserActivation::TRANSIENT_ACTIVATION_DURATION)
    refute @win.__internal_transient_activation__?
    assert @win.__internal_sticky_activation__?
  end

  def test_driver_events_are_trusted_and_script_events_are_not
    trusted = {}
    %w[pointerdown mousedown click keydown].each do |type|
      el("b").add_event_listener(type, ->(e) { trusted[type] = e.__js_get__("isTrusted") })
    end
    synth.click(el("b"))
    synth.keydown(el("b"), "a", "KeyA")
    assert_equal({"pointerdown" => true, "mousedown" => true, "click" => true, "keydown" => true}, trusted)

    el("b").dispatch_event(Dommy::MouseEvent.new("mousedown", "bubbles" => true))
    assert_equal false, trusted["mousedown"]
  end

  def test_script_dispatched_input_does_not_activate
    el("b").dispatch_event(Dommy::MouseEvent.new("mousedown", "bubbles" => true))
    el("b").click
    refute @win.__internal_sticky_activation__?
  end

  def test_escape_does_not_activate_but_other_keys_do
    synth.keydown(el("b"), "Escape", "Escape")
    refute @win.__internal_sticky_activation__?
    synth.keydown(el("b"), "a", "KeyA")
    assert @win.__internal_transient_activation__?
  end

  def test_show_picker_needs_transient_activation_and_consumes_it
    assert_raises(Dommy::DOMException::NotAllowedError) { el("date").show_picker }
    synth.click(el("b"))
    el("date").show_picker
    refute @win.__internal_transient_activation__?
    assert @win.__internal_sticky_activation__?
    assert_raises(Dommy::DOMException::NotAllowedError) { el("s").show_picker }
  end

  def test_activation_and_its_consumption_reach_same_origin_frames
    frame_win = Dommy::Window.new
    iframe = @doc.create_element("iframe")
    @doc.body.append_child(iframe)
    iframe.__internal_set_content_document__(frame_win.document)
    synth.click(el("b"))
    assert frame_win.__internal_transient_activation__?
    @win.__internal_consume_user_activation__
    refute frame_win.__internal_transient_activation__?
    assert frame_win.__internal_sticky_activation__?
  end
end
