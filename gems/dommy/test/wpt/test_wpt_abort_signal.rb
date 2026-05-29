# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for AbortController / AbortSignal.
# WPT: dom/abort/*, fetch/api/abort/*
class TestWPTAbortControllerBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- construction ----
  # WPT: dom/abort/event.any.js

  def test_new_controller_signal_not_aborted
    ctrl = Dommy::AbortController.new
    refute(ctrl.signal.aborted?)
  end

  def test_new_controller_signal_reason_nil
    ctrl = Dommy::AbortController.new
    assert_nil(ctrl.signal.reason)
  end

  def test_controller_signal_is_AbortSignal
    ctrl = Dommy::AbortController.new
    assert_kind_of(Dommy::AbortSignal, ctrl.signal)
  end

  def test_signal_accessible_via_js_bridge
    ctrl = Dommy::AbortController.new
    assert_same(ctrl.signal, ctrl.__js_get__("signal"))
  end

  # ---- abort() ----

  def test_abort_flips_aborted_to_true
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", [])
    assert(ctrl.signal.aborted?)
  end

  def test_abort_with_reason_stores_reason
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", ["timeout"])
    assert_equal("timeout", ctrl.signal.reason)
  end

  def test_abort_with_exception_reason_stores_exception
    err = RuntimeError.new("user cancelled")
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", [err])
    assert_same(err, ctrl.signal.reason)
  end

  def test_double_abort_keeps_first_reason
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", ["first"])
    ctrl.__js_call__("abort", ["second"])
    assert_equal("first", ctrl.signal.reason)
  end
end

class TestWPTAbortSignalEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  # ---- abort event ----
  # WPT: dom/abort/event.any.js

  def test_abort_event_fires_when_aborted
    ctrl = Dommy::AbortController.new
    fired = false
    ctrl.signal.add_event_listener("abort", proc { fired = true })
    ctrl.__js_call__("abort", [])
    assert(fired)
  end

  def test_abort_event_fires_only_once
    ctrl = Dommy::AbortController.new
    count = 0
    ctrl.signal.add_event_listener("abort", proc { count += 1 })
    ctrl.__js_call__("abort", [])
    ctrl.__js_call__("abort", [])
    assert_equal(1, count)
  end

  def test_abort_listener_via_js_bridge
    ctrl = Dommy::AbortController.new
    fired = false
    ctrl.signal.__js_call__("addEventListener", ["abort", proc { fired = true }])
    ctrl.__js_call__("abort", [])
    assert(fired)
  end
end

class TestWPTAbortSignalThrowIfAborted < Minitest::Test
  include DommyTestHelper

  # ---- throwIfAborted ----
  # WPT: dom/abort/throw-if-aborted.any.js

  def test_throwIfAborted_no_op_when_not_aborted
    ctrl = Dommy::AbortController.new
    assert_nil(ctrl.signal.throw_if_aborted)
  end

  def test_throwIfAborted_raises_exception_reason
    ctrl = Dommy::AbortController.new
    err = RuntimeError.new("boom")
    ctrl.__js_call__("abort", [err])
    raised = assert_raises(RuntimeError) { ctrl.signal.throw_if_aborted }
    assert_same(err, raised)
  end

  def test_throwIfAborted_raises_RuntimeError_when_reason_is_string
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", ["timeout"])
    raised = assert_raises(RuntimeError) { ctrl.signal.throw_if_aborted }
    assert_equal("timeout", raised.message)
  end

  def test_throwIfAborted_via_js_bridge
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", ["fail"])
    assert_raises(RuntimeError) { ctrl.signal.__js_call__("throwIfAborted", []) }
  end
end

class TestWPTAbortSignalEventListener < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>x</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  # ---- AbortSignal + addEventListener options ----
  # WPT: dom/events/AddEventListenerOptions-signal.any.js (covered in
  # test_wpt_events.rb session 1 too)

  def test_abort_removes_event_listener_from_element
    ctrl = Dommy::AbortController.new
    count = 0
    @btn.add_event_listener("click", proc { count += 1 }, {"signal" => ctrl.signal})
    @btn.click
    assert_equal(1, count)
    ctrl.__js_call__("abort", [])
    @btn.click
    assert_equal(1, count)
  end

  def test_already_aborted_signal_skips_registration_entirely
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", [])
    count = 0
    @btn.add_event_listener("click", proc { count += 1 }, {"signal" => ctrl.signal})
    @btn.click
    assert_equal(0, count)
  end

  def test_multiple_listeners_share_signal
    ctrl = Dommy::AbortController.new
    a = 0
    b = 0
    @btn.add_event_listener("click", proc { a += 1 }, {"signal" => ctrl.signal})
    @btn.add_event_listener("click", proc { b += 1 }, {"signal" => ctrl.signal})
    @btn.click
    ctrl.__js_call__("abort", [])
    @btn.click
    assert_equal(1, a)
    assert_equal(1, b)
  end
end
