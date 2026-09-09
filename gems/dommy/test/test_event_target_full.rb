# frozen_string_literal: true

require_relative "test_helper"

# Round out EventTarget coverage to match happy-dom's spec compliance:
# handleEvent objects, listener dedup, scope verification, and
# during-dispatch removal.
class TestEventTargetFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @btn = @win.document.get_element_by_id("b")
  end

  def test_handle_event_object_listener
    received = nil
    obj = Class
      .new {
        define_method(:handle_event) { |e| received = e.__js_get__("type") }
      }
      .new
    @btn.add_event_listener("click", obj)
    @btn.click
    assert_equal("click", received)
  end

  def test_listener_dedup_same_function
    count = 0
    handler = proc { count += 1 }
    @btn.add_event_listener("click", handler)
    @btn.add_event_listener("click", handler)
    @btn.add_event_listener("click", handler)
    @btn.click
    assert_equal(1, count)
  end

  def test_different_listener_instances_both_fire
    count = 0
    @btn.add_event_listener("click", proc { count += 1 })
    @btn.add_event_listener("click", proc { count += 1 })
    @btn.click
    assert_equal(2, count)
  end

  def test_remove_event_listener_with_handler_object
    received = []
    obj = Class
      .new {
        define_method(:handle_event) { |_e| received << :ran }
      }
      .new
    @btn.add_event_listener("click", obj)
    @btn.click
    @btn.remove_event_listener("click", obj)
    @btn.click
    assert_equal([:ran], received)
  end

  def test_listener_removed_during_dispatch_is_not_invoked
    seen = []
    later_handler = proc { seen << :later }
    @btn.add_event_listener(
      "click",
      proc {
        seen << :first
        @btn.remove_event_listener("click", later_handler)
      }
    )
    @btn.add_event_listener("click", later_handler)
    @btn.click
    # WHATWG "inner invoke" walks a snapshot of the listener list but skips any
    # entry whose removed flag is set, so removing a not-yet-invoked listener
    # from an earlier listener cancels it for this dispatch too.
    assert_equal([:first], seen)
  end

  def test_listener_added_during_dispatch_is_not_invoked
    seen = []
    @btn.add_event_listener("click", proc { @btn.add_event_listener("click", proc { seen << :late }) })
    @btn.click
    assert_empty(seen)
  end

  # A once listener a NESTED dispatch consumed is flagged removed, so the outer
  # dispatch still walking its snapshot skips it (WPT remove-all-listeners).
  def test_a_once_listener_consumed_by_a_nested_dispatch_is_not_run_again
    counts = Hash.new(0)
    second = proc { counts[:second] += 1 }
    first = proc do
      counts[:first] += 1
      @btn.dispatch_event(Dommy::Event.new("foo"))
    end
    @btn.add_event_listener("foo", first, { "once" => true })
    @btn.add_event_listener("foo", second, { "once" => true })

    @btn.dispatch_event(Dommy::Event.new("foo"))
    assert_equal({first: 1, second: 1}, counts)
  end

  def test_throwing_listener_is_reported_as_a_window_error_event
    reported = nil
    @win.add_event_listener("error", proc { |e| reported = e })
    boom = RuntimeError.new("boom")
    @btn.add_event_listener("click", proc { raise boom })
    # The throw must NOT escape dispatch; it is reported instead.
    @btn.dispatch_event(Dommy::MouseEvent.new("click", "bubbles" => true))

    refute_nil(reported, "a throwing listener fires an error event on the window")
    assert_equal("error", reported.type)
    assert_same(boom, reported.__js_get__("error"), "event.error is the thrown value")
    assert_equal("boom", reported.__js_get__("message"))
  end

  # HTML's event handler processing algorithm: the special error event handler
  # (`window.onerror`) is called with (message, filename, lineno, colno, error)
  # rather than the event, and returning true cancels the event.
  def test_window_onerror_receives_the_five_arguments_and_cancels_on_true
    seen = nil
    @win.__js_set__("onerror", proc { |*args| seen = args; true })
    reported = nil
    @win.add_event_listener("error", proc { |e| reported = e })
    boom = RuntimeError.new("boom")
    @btn.add_event_listener("click", proc { raise boom })
    @btn.dispatch_event(Dommy::MouseEvent.new("click", "bubbles" => true))

    assert_equal ["boom", "", 0, 0, boom], seen
    assert reported.default_prevented?, "onerror returning true cancels the error event"
  end

  def test_error_report_reentrancy_is_guarded
    # An "error" handler that itself throws must not recurse into another report.
    count = 0
    @win.add_event_listener("error", proc { count += 1; raise "again" })
    @btn.add_event_listener("click", proc { raise "first" })
    @btn.dispatch_event(Dommy::MouseEvent.new("click", "bubbles" => true))

    assert_equal(1, count, "the error handler runs once, its own throw is not re-reported")
  end

  def test_dispatch_event_returns_true_when_no_default_prevented
    result = @btn.dispatch_event(Dommy::Event.new("click", "cancelable" => true))
    assert_equal(true, result)
  end

  def test_dispatch_event_returns_false_when_prevented
    @btn.on("click") { |e| e.__js_call__("preventDefault", []) }
    result = @btn.dispatch_event(Dommy::Event.new("click", "cancelable" => true))
    assert_equal(false, result)
  end

  def test_dispatch_event_returns_true_when_no_listeners
    result = @btn.dispatch_event(Dommy::Event.new("never-fired"))
    assert_equal(true, result)
  end
end
