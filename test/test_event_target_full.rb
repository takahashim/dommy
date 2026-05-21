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

  def test_listener_removed_during_dispatch_still_completes_current
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
    # The snapshot taken at dispatch start still invokes `later_handler`.
    assert_equal([:first, :later], seen)
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
