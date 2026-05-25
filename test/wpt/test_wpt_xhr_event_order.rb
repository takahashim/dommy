# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for XMLHttpRequest event firing order on the
# happy path (loadstart -> readystatechange*3 -> load -> loadend).
#
# WPT: xhr/event-loadstart.any.js,
#      xhr/event-readystatechange-loaded.any.js,
#      xhr/event-loadend.any.js
# Spec: https://xhr.spec.whatwg.org/#events
#
# Complements test/test_xml_http_request.rb which covers individual
# event firing but not the full sequence or interleaving with
# readyState transitions.
class TestWPTXHREventOrder < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "ok", "contentType" => "text/plain" }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
    @events = []
  end

  def record(*names)
    names.each do |name|
      @xhr.add_event_listener(name, proc { |_e| @events << name })
    end
  end

  def test_loadstart_fires_synchronously_during_send
    record("loadstart")
    @xhr.open("GET", "/ok")
    @xhr.send
    # loadstart is dispatched inside send(), before any microtask runs.
    assert_equal(["loadstart"], @events)
  end

  def test_load_does_not_fire_until_microtask_drained
    record("load")
    @xhr.open("GET", "/ok")
    @xhr.send
    assert_equal([], @events)
    @win.scheduler.drain_microtasks
    assert_equal(["load"], @events)
  end

  def test_open_dispatches_one_readystatechange
    # `open()` transitions UNSENT -> OPENED and fires one
    # readystatechange synchronously.
    record("readystatechange")
    @xhr.open("GET", "/ok")
    assert_equal(["readystatechange"], @events)
  end

  def test_full_event_order_on_successful_request
    # Full sequence from a freshly-constructed XHR: open() fires
    # readystatechange (UNSENT -> OPENED); send() fires loadstart
    # synchronously; after the microtask drain, readystatechange
    # fires 3 more times (HEADERS_RECEIVED -> LOADING -> DONE)
    # followed by load and loadend.
    record("loadstart", "readystatechange", "load", "loadend")
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert_equal(
      ["readystatechange",  # OPENED, fired by open()
       "loadstart",
       "readystatechange", "readystatechange", "readystatechange",
       "load", "loadend"],
      @events
    )
  end

  def test_load_fires_before_loadend
    fired = []
    @xhr.add_event_listener("load", proc { |_e| fired << :load })
    @xhr.add_event_listener("loadend", proc { |_e| fired << :loadend })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert_equal(%i[load loadend], fired)
  end

  def test_ready_state_is_done_when_load_fires
    state_at_load = nil
    @xhr.add_event_listener("load", proc { |_e| state_at_load = @xhr.ready_state })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert_equal(Dommy::XMLHttpRequest::DONE, state_at_load)
  end
end
