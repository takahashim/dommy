# frozen_string_literal: true

require_relative "test_helper"

class TestSignalOnce < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  def test_once_listener_fires_only_once
    count = 0
    @btn.add_event_listener("click", proc { count += 1 }, {"once" => true})
    @btn.click
    @btn.click
    @btn.click
    assert_equal(1, count)
  end

  def test_signal_removes_listener_on_abort
    ctrl = Dommy::AbortController.new
    fired = 0
    @btn.add_event_listener("click", proc { fired += 1 }, {"signal" => ctrl.signal})

    @btn.click
    assert_equal(1, fired)

    ctrl.__js_call__("abort", [])

    @btn.click
    assert_equal(1, fired)
  end

  def test_signal_already_aborted_skips_registration_after_abort
    ctrl = Dommy::AbortController.new
    ctrl.__js_call__("abort", [])

    fired = 0
    @btn.add_event_listener("click", proc { fired += 1 }, {"signal" => ctrl.signal})
    @btn.click
    # The listener is removed when "abort" fires; here abort has
    # already fired, so the listener is removed immediately via the
    # signal addEventListener path. Click should not invoke it.
    assert_equal(0, fired)
  end
end
