# frozen_string_literal: true

require_relative "test_helper"

# Popover invokers (popovertarget / popovertargetaction) and invoker commands
# (commandfor / command, CommandEvent) on button and input.
class TestInvokers < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <div id="p" popover>pop</div>
      <button id="toggler" popovertarget="p">toggle</button>
      <button id="shower" popovertarget="p" popovertargetaction="show">show</button>
      <input id="inp" type="button" popovertarget="p">
      <form id="f"><button id="in-form" popovertarget="p">submit</button>
        <button id="cmd-in-form" commandfor="p" command="show-popover">x</button>
        <button id="typed-in-form" type="button" commandfor="p" command="show-popover">x</button></form>
      <button id="cmd" commandfor="p" command="toggle-popover">cmd</button>
      <button id="custom" commandfor="p" command="--go">custom</button>
    HTML
    @doc = @win.document
    @events = []
    @submits = 0
    el("f").add_event_listener("submit", proc { |e| @submits += 1; e.__js_call__("preventDefault", []) })
  end

  def el(id) = @doc.get_element_by_id(id)

  def showing? = el("p").matches?(":popover-open")

  def test_reflection
    assert_same el("p"), el("toggler").popover_target_element
    assert_equal "toggle", el("toggler").popover_target_action
    assert_equal "show", el("shower").popover_target_action
    el("shower").set_attribute("popovertargetaction", "bogus")
    assert_equal "toggle", el("shower").popover_target_action
    el("toggler").popover_target_element = el("cmd")
    assert_equal "", el("toggler").get_attribute("popovertarget")
    assert_same el("cmd"), el("toggler").popover_target_element
  end

  def test_popovertarget_toggles_with_the_invoker_as_source
    sources = []
    el("p").add_event_listener("beforetoggle", proc { |e| sources << e.source&.id })
    el("toggler").click
    assert showing?
    el("toggler").click
    refute showing?
    assert_equal %w[toggler toggler], sources
  end

  def test_show_action_does_not_hide
    el("shower").click
    el("shower").click
    assert showing?
  end

  def test_input_button_invokes
    el("inp").click
    assert showing?
  end

  def test_a_submit_button_with_a_form_owner_submits_instead
    el("in-form").click
    refute showing?
    assert_equal 1, @submits
  end

  def test_button_type_with_commandfor
    assert_equal "submit", el("in-form").type
    assert_equal "button", el("cmd-in-form").type
    assert_equal "button", el("cmd").type
  end

  def test_a_commandfor_button_in_a_form_neither_submits_nor_invokes
    el("cmd-in-form").click
    assert_equal 0, @submits
    refute showing?
    el("typed-in-form").click
    assert showing?
  end

  def test_command_fires_a_cancelable_command_event_then_runs
    el("p").add_event_listener("command", proc { |e| @events << [e.command, e.source.id, e.__js_get__("cancelable")] })
    el("cmd").click
    assert_equal [["toggle-popover", "cmd", true]], @events
    assert showing?
  end

  def test_a_canceled_command_does_nothing
    el("p").add_event_listener("command", proc { |e| e.__js_call__("preventDefault", []) })
    el("cmd").click
    refute showing?
  end

  def test_custom_commands_only_fire_the_event
    el("p").add_event_listener("command", proc { |e| @events << e.command })
    el("custom").click
    assert_equal ["--go"], @events
    refute showing?
  end

  def test_command_getter
    button = el("cmd")
    button.set_attribute("command", "SHOW-Modal")
    assert_equal "show-modal", button.command
    button.set_attribute("command", "--CaSe")
    assert_equal "--CaSe", button.command
    button.set_attribute("command", "nope")
    assert_equal "", button.command
  end
end
