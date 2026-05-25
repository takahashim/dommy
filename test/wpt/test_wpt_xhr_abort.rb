# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for XMLHttpRequest abort() in various readyState
# transitions and its interaction with status / event sequence.
#
# WPT: xhr/abort-after-receive.any.js,
#      xhr/abort-during-open.any.js,
#      xhr/abort-during-done.any.js,
#      xhr/abort-event-order.any.js
# Spec: https://xhr.spec.whatwg.org/#the-abort()-method
#
# Complements test/test_xml_http_request.rb's
# test_abort_resets_state_and_fires_event /
# test_abort_prevents_completion_callback by covering the no-op
# states (UNSENT, DONE) and the abort event ordering.
class TestWPTXHRAbortInUnsentState < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @xhr = Dommy::XMLHttpRequest.new(@win)
  end

  def test_abort_in_unsent_state_is_noop
    fired = []
    @xhr.add_event_listener("abort", proc { |_e| fired << :abort })
    @xhr.add_event_listener("loadend", proc { |_e| fired << :loadend })
    @xhr.abort
    # Spec: if readyState is UNSENT, abort() does nothing.
    assert_empty(fired)
    assert_equal(Dommy::XMLHttpRequest::UNSENT, @xhr.ready_state)
  end

  def test_abort_in_unsent_does_not_change_state
    @xhr.abort
    assert_equal(Dommy::XMLHttpRequest::UNSENT, @xhr.ready_state)
    assert_equal(0, @xhr.status)
  end
end

class TestWPTXHRAbortInOpenedState < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "ok", "contentType" => "text/plain" }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
    @xhr.open("GET", "/ok")
  end

  def test_abort_after_open_but_before_send_fires_abort_and_loadend
    # Dommy's abort() short-circuits only for UNSENT and DONE states;
    # in OPENED it still dispatches abort + loadend. (The WHATWG
    # spec also makes the send() flag a factor, but Dommy tracks
    # only readyState.) Verify the firing pattern as-implemented.
    fired = []
    @xhr.add_event_listener("abort", proc { |_e| fired << :abort })
    @xhr.add_event_listener("loadend", proc { |_e| fired << :loadend })
    @xhr.abort
    assert_equal(%i[abort loadend], fired)
  end
end

class TestWPTXHRAbortDuringRequest < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/slow" => { "status" => 200, "body" => "ok",
                   "contentType" => "text/plain", "delay" => 1000 }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
  end

  def test_abort_during_in_flight_request_fires_abort_and_loadend
    @xhr.open("GET", "/slow")
    @xhr.send
    fired = []
    @xhr.add_event_listener("abort", proc { |_e| fired << :abort })
    @xhr.add_event_listener("loadend", proc { |_e| fired << :loadend })
    @xhr.abort
    assert_equal(%i[abort loadend], fired)
  end

  def test_abort_during_in_flight_resets_status_to_zero
    @xhr.open("GET", "/slow")
    @xhr.send
    @xhr.abort
    assert_equal(0, @xhr.status)
    assert_equal("", @xhr.status_text)
  end

  def test_abort_during_in_flight_resets_ready_state_to_unsent
    # WHATWG would leave readyState at DONE after abort; Dommy's
    # abort() calls reset_state(keep_handlers: true) which reverts
    # readyState to UNSENT to allow the same XHR instance to be
    # re-opened. Verify this Dommy-specific behaviour.
    @xhr.open("GET", "/slow")
    @xhr.send
    @xhr.abort
    assert_equal(Dommy::XMLHttpRequest::UNSENT, @xhr.ready_state)
  end

  def test_abort_during_in_flight_prevents_load_event
    @xhr.open("GET", "/slow")
    @xhr.send
    fired = []
    @xhr.add_event_listener("load", proc { |_e| fired << :load })
    @xhr.abort
    @win.scheduler.advance_time(2000) # past the 1000ms delay
    refute_includes(fired, :load)
  end
end

class TestWPTXHRAbortInDoneState < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "done", "contentType" => "text/plain" }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    # readyState is now DONE after a successful response.
  end

  def test_abort_in_done_state_is_noop_for_events
    fired = []
    @xhr.add_event_listener("abort", proc { |_e| fired << :abort })
    @xhr.add_event_listener("loadend", proc { |_e| fired << :loadend })
    @xhr.abort
    # Spec: abort() does nothing if readyState is DONE.
    assert_empty(fired)
  end

  def test_abort_in_done_state_preserves_status
    @xhr.abort
    # Status from the completed request must be preserved.
    assert_equal(200, @xhr.status)
  end
end

class TestWPTXHRAbortEventOrder < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/slow" => { "status" => 200, "body" => "x",
                   "contentType" => "text/plain", "delay" => 500 }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
    @xhr.open("GET", "/slow")
    @xhr.send
  end

  def test_event_order_during_abort
    # Spec: readyState transitions to DONE (fires readystatechange),
    # then abort, then loadend.
    events = []
    @xhr.add_event_listener("readystatechange",
                            proc { |_e| events << "readystatechange" })
    @xhr.add_event_listener("abort", proc { |_e| events << "abort" })
    @xhr.add_event_listener("loadend", proc { |_e| events << "loadend" })
    @xhr.abort
    assert_equal(["readystatechange", "abort", "loadend"], events)
  end
end
