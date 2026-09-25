# frozen_string_literal: true

require_relative "test_helper"

# `<dialog>` fires `beforetoggle` synchronously (before the open attribute
# changes; an opening can be canceled) and `toggle` asynchronously, coalescing
# rapid changes.
# Mirrors WPT html/semantics/interactive-elements/the-dialog-element/
# toggle-events.html.
class TestDialogToggleEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<dialog id='d'>dialog</dialog>")
    @doc = @win.document
    @dialog = @doc.get_element_by_id("d")
    @events = []
    @dialog.add_event_listener("beforetoggle", proc { |e| record("beforetoggle", e) })
    @dialog.add_event_listener("toggle", proc { |e| record("toggle", e) })
  end

  def record(type, event)
    @events << [type, event.__js_get__("oldState"), event.__js_get__("newState"), @dialog.has_attribute?("open")]
  end

  def test_show_fires_beforetoggle_sync_and_toggle_async
    @dialog.show
    assert_equal [["beforetoggle", "closed", "open", false]], @events

    @win.scheduler.advance_time(0)
    assert_equal [
      ["beforetoggle", "closed", "open", false],
      ["toggle", "closed", "open", true]
    ], @events
  end

  def test_close_fires_beforetoggle_sync_and_toggle_async
    @dialog.show
    @win.scheduler.advance_time(0)
    @events.clear

    @dialog.close
    assert_equal [["beforetoggle", "open", "closed", true]], @events

    @win.scheduler.advance_time(0)
    assert_equal [
      ["beforetoggle", "open", "closed", true],
      ["toggle", "open", "closed", false]
    ], @events
  end

  def test_show_modal_fires_the_same_pair
    @dialog.show_modal
    assert_equal [["beforetoggle", "closed", "open", false]], @events
    @win.scheduler.advance_time(0)
    assert_equal 2, @events.length
  end

  def test_canceled_beforetoggle_aborts
    @dialog.add_event_listener("beforetoggle", proc { |e| e.__js_call__("preventDefault", []) })
    @dialog.show
    refute @dialog.has_attribute?("open")
  end

  def test_closing_beforetoggle_cannot_be_canceled
    @dialog.show
    cancelable = nil
    @dialog.add_event_listener("beforetoggle", proc { |e|
      cancelable = e.__js_get__("cancelable")
      e.__js_call__("preventDefault", [])
    })
    @dialog.close
    assert_equal false, cancelable
    refute @dialog.has_attribute?("open")
  end

  def test_rapid_changes_coalesce_into_one_toggle
    @dialog.show
    @dialog.close
    @win.scheduler.advance_time(0)
    assert_equal [["toggle", "closed", "closed", false]], @events.select { |e| e.first == "toggle" }
  end

  # WHATWG "show()" steps: an open dialog with `is modal` false (i.e. shown via
  # show(), not showModal()) makes show() a silent no-op.
  def test_show_on_open_non_modal_dialog_is_a_noop
    @dialog.show
    @win.scheduler.advance_time(0)
    @events.clear

    @dialog.show
    assert_empty @events
    assert @dialog.has_attribute?("open")
  end

  # WHATWG "show()" steps: an open dialog with `is modal` true (i.e. shown via
  # showModal()) makes show() throw InvalidStateError.
  def test_show_on_open_modal_dialog_raises
    @dialog.show_modal
    assert_raises(Dommy::DOMException::InvalidStateError) { @dialog.show }
  end

  # WHATWG "show a modal dialog" steps: an open, non-modal dialog makes
  # showModal() throw InvalidStateError.
  def test_show_modal_on_open_non_modal_dialog_raises
    @dialog.show
    assert_raises(Dommy::DOMException::InvalidStateError) { @dialog.show_modal }
  end

  # WHATWG "show a modal dialog" steps: an open, already-modal dialog makes
  # showModal() a silent no-op.
  def test_show_modal_on_open_modal_dialog_is_a_noop
    @dialog.show_modal
    @win.scheduler.advance_time(0)
    @events.clear

    @dialog.show_modal
    assert_empty @events
    assert @dialog.has_attribute?("open")
  end

  # WHATWG "show a modal dialog" steps: a dialog already showing as a popover
  # cannot also be shown as a modal dialog.
  def test_show_modal_on_a_dialog_showing_as_a_popover_raises
    @dialog.set_attribute("popover", "manual")
    @dialog.show_popover
    assert_raises(Dommy::DOMException::InvalidStateError) { @dialog.show_modal }
  end

  # A beforetoggle listener that closes the dialog again from inside its own
  # handler leaves the outer close() call with nothing further to do.
  def test_close_rechecks_open_after_beforetoggle
    @dialog.show
    @win.scheduler.advance_time(0)
    @events.clear
    reentered = false
    @dialog.add_event_listener("beforetoggle", proc { |e|
      if e.__js_get__("newState") == "closed" && !reentered
        reentered = true
        @dialog.close("reentrant")
      end
    })

    @dialog.close("outer")
    assert_equal "reentrant", @dialog.return_value
    refute @dialog.has_attribute?("open")
    # Only the reentrant close() queued a toggle/close pair; the outer call's
    # own toggle was superseded rather than duplicated.
    @win.scheduler.advance_time(0)
    assert_equal 1, @events.count { |e| e.first == "toggle" }
  end

  # WHATWG gives `<details>`, `<dialog>`, and popovers their own toggle task
  # tracker apiece. A `<dialog popover>` shown both ways in the same task must
  # therefore fire TWO separate `toggle` events (one per purpose) rather than
  # coalescing them into one, even though both land on the same element.
  def test_dialog_popover_toggle_events_are_tracked_separately
    win = make_window("<dialog id='d' popover='manual'>dialog</dialog>")
    dialog = win.document.get_element_by_id("d")
    toggles = []
    dialog.add_event_listener("toggle", proc { |e| toggles << [e.__js_get__("oldState"), e.__js_get__("newState")] })

    dialog.show
    dialog.show_popover
    win.scheduler.advance_time(0)

    assert_equal [%w[closed open], %w[closed open]], toggles
  end
end
