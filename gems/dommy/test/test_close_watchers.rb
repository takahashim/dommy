# frozen_string_literal: true

require_relative "test_helper"

# HTML §6.9 close requests and close watchers, and light dismiss: Esc from
# the driver closes the topmost modal dialog, auto popover or CloseWatcher;
# clicking outside closes auto popovers and closedby=any dialogs.
class TestCloseWatchers < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <button id="outside">outside</button>
      <div id="pop" popover><button id="in-pop">in</button></div>
      <div id="manual" popover="manual">manual</div>
      <dialog id="dlg"><button id="in-dlg">in</button></dialog>
      <dialog id="any" closedby="any"><button id="in-any">in</button></dialog>
    HTML
    @doc = @win.document
    @events = []
  end

  def el(id) = @doc.get_element_by_id(id)
  def synth = Dommy::Interaction::EventSynthesis

  def escape(target = @doc.body)
    sender = Dommy::Interaction::KeySender.new(Dommy::Interaction::FieldInteractor.new(nil, @doc))
    sender.dispatch(target, :escape)
  end

  def record(element)
    %w[cancel close].each do |type|
      element.add_event_listener(type, ->(e) { @events << "#{type}#{"(cancelable)" if e.__js_get__("cancelable")}" })
    end
  end

  def test_escape_closes_a_modal_dialog_with_a_cancel_event
    record(el("dlg"))
    el("dlg").show_modal
    escape(el("in-dlg"))
    refute el("dlg").has_attribute?("open")
    @win.scheduler.advance_time(0)
    assert_equal %w[cancel close], @events
  end

  def test_escape_leaves_a_non_modal_dialog_open
    el("dlg").show
    escape
    assert el("dlg").has_attribute?("open")
  end

  def test_a_canceled_escape_keydown_closes_nothing
    el("dlg").show_modal
    @doc.add_event_listener("keydown", ->(e) { e.__js_call__("preventDefault", []) })
    escape(el("in-dlg"))
    assert el("dlg").has_attribute?("open")
  end

  def test_escape_hides_the_topmost_auto_popover_only
    el("manual").show_popover
    el("pop").show_popover
    escape
    refute el("pop").matches?(":popover-open")
    assert el("manual").matches?(":popover-open")
  end

  def test_a_close_watcher_with_activation_can_cancel_the_close_request
    # User activation lets a close watcher's cancel event be canceled once.
    synth.click(el("outside"))
    watcher = Dommy::CloseWatcher.new(@win)
    watcher.add_event_listener("cancel", lambda { |e|
      @events << "cancel#{"(cancelable)" if e.__js_get__("cancelable")}"
      e.__js_call__("preventDefault", [])
    })
    watcher.add_event_listener("close", ->(_e) { @events << "close" })
    escape
    assert_equal %w[cancel(cancelable)], @events
    # That used the activation up: the next close request cannot be stopped.
    escape
    assert_equal %w[cancel(cancelable) cancel close], @events
  end

  def test_close_watchers_created_without_activation_close_together
    first = Dommy::CloseWatcher.new(@win)
    second = Dommy::CloseWatcher.new(@win)
    first.add_event_listener("close", ->(_e) { @events << "first" })
    second.add_event_listener("close", ->(_e) { @events << "second" })
    escape
    assert_equal %w[second first], @events
  end

  def test_destroyed_close_watcher_fires_nothing
    watcher = Dommy::CloseWatcher.new(@win)
    watcher.add_event_listener("close", ->(_e) { @events << "close" })
    watcher.destroy
    escape
    watcher.request_close
    assert_empty @events
  end

  def test_request_close_on_a_dialog_fires_a_cancelable_cancel
    el("dlg").show
    record(el("dlg"))
    el("dlg").add_event_listener("cancel", ->(e) { e.__js_call__("preventDefault", []) })
    el("dlg").request_close
    assert el("dlg").has_attribute?("open")
    assert_equal ["cancel(cancelable)"], @events
  end

  def test_clicking_outside_hides_an_auto_popover
    el("pop").show_popover
    synth.click(el("in-pop"))
    assert el("pop").matches?(":popover-open")
    synth.click(el("outside"))
    refute el("pop").matches?(":popover-open")
  end

  def test_clicking_outside_leaves_a_manual_popover
    el("manual").show_popover
    synth.click(el("outside"))
    assert el("manual").matches?(":popover-open")
  end

  def test_light_dismiss_closes_before_pointerup_is_dispatched
    el("pop").show_popover
    order = []
    el("pop").add_event_listener("beforetoggle", ->(_e) { order << "beforetoggle" })
    %w[pointerdown pointerup click].each { |t| @doc.add_event_listener(t, ->(_e) { order << t }) }
    synth.click(el("outside"))
    assert_equal %w[pointerdown beforetoggle pointerup click], order
  end

  def test_clicking_the_backdrop_closes_a_closedby_any_dialog
    el("any").show_modal
    synth.click(el("in-any"))
    assert el("any").has_attribute?("open")
    # Outside the modal dialog everything is inert: the press lands on its
    # backdrop.
    synth.click(el("outside"))
    refute el("any").has_attribute?("open")
  end

  def test_clicking_the_backdrop_leaves_a_default_modal_dialog
    el("dlg").show_modal
    synth.click(el("outside"))
    assert el("dlg").has_attribute?("open")
  end
end
