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
end
