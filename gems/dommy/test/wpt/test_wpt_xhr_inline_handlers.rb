# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for XMLHttpRequest inline event-handler properties
# (`onreadystatechange`, `onloadstart`, `onload`, `onloadend`,
# `onabort`, `ontimeout`).
#
# WPT: xhr/event-readystatechange-loaded.any.js,
#      xhr/event-onloadstart.any.js,
#      xhr/event-onload.any.js,
#      xhr/event-onloadend.any.js,
#      xhr/event-abort.any.js,
#      xhr/event-timeout.any.js
# Spec: https://xhr.spec.whatwg.org/#interface-xmlhttprequest
#       (the `onfoo` IDL attributes section)
#
# Dommy exposes these as `__js_set__("onfoo", handler)` rather than
# Ruby attr_accessors — the JS bridge keeps the surface area small
# and pushes registration through the same `set_inline_handler` path
# regardless of event name. These tests exercise that bridge.
#
# Existing test/test_xml_http_request.rb covers `onload`. This file
# covers the remaining six handlers plus the inline-handler
# replacement semantics.
class TestWPTXHRInlineHandlersFiring < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "ok", "contentType" => "text/plain" },
      "/slow" => { "status" => 200, "body" => "x",
                   "contentType" => "text/plain", "delay" => 1000 }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
  end

  def test_onreadystatechange_fires_for_each_transition
    states = []
    @xhr.__js_set__("onreadystatechange", proc { |_e| states << @xhr.ready_state })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert_equal([1, 2, 3, 4], states)
  end

  def test_onloadstart_fires_on_send
    fired = false
    @xhr.__js_set__("onloadstart", proc { |_e| fired = true })
    @xhr.open("GET", "/ok")
    @xhr.send
    # loadstart is synchronous in send().
    assert(fired)
  end

  def test_onload_fires_on_completion
    fired = false
    @xhr.__js_set__("onload", proc { |_e| fired = true })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert(fired)
  end

  def test_onloadend_fires_on_completion
    fired = false
    @xhr.__js_set__("onloadend", proc { |_e| fired = true })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert(fired)
  end

  def test_onabort_fires_on_abort
    fired = false
    @xhr.__js_set__("onabort", proc { |_e| fired = true })
    @xhr.open("GET", "/slow")
    @xhr.send
    @xhr.abort
    assert(fired)
  end

  def test_ontimeout_fires_when_request_exceeds_timeout
    fired = false
    @xhr.__js_set__("ontimeout", proc { |_e| fired = true })
    @xhr.timeout = 100
    @xhr.open("GET", "/slow") # /slow has delay: 1000ms
    @xhr.send
    @win.scheduler.advance_time(150)
    assert(fired)
  end
end

class TestWPTXHRInlineHandlerReplacement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "ok", "contentType" => "text/plain" }
    })
    @xhr = Dommy::XMLHttpRequest.new(@win)
  end

  def test_setting_handler_replaces_previous_one
    # Per WHATWG IDL: assigning to an `onfoo` slot removes the
    # previous listener for that event. Verify only the newest
    # handler fires.
    first_fired = false
    second_fired = false
    @xhr.__js_set__("onload", proc { |_e| first_fired = true })
    @xhr.__js_set__("onload", proc { |_e| second_fired = true })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    refute(first_fired)
    assert(second_fired)
  end

  def test_setting_handler_to_nil_clears_it
    fired = false
    handler = proc { |_e| fired = true }
    @xhr.__js_set__("onload", handler)
    @xhr.__js_set__("onload", nil)
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    refute(fired)
  end

  def test_inline_handler_and_add_event_listener_both_fire
    inline_fired = false
    listener_fired = false
    @xhr.__js_set__("onload", proc { |_e| inline_fired = true })
    @xhr.add_event_listener("load", proc { |_e| listener_fired = true })
    @xhr.open("GET", "/ok")
    @xhr.send
    @win.scheduler.drain_microtasks
    assert(inline_fired)
    assert(listener_fired)
  end
end

class TestWPTXHRInlineHandlerReadback < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @xhr = Dommy::XMLHttpRequest.new(@win)
  end

  def test_handler_readback_via_js_get
    handler = proc { |_e| }
    @xhr.__js_set__("onload", handler)
    assert_same(handler, @xhr.__js_get__("onload"))
  end

  def test_unset_handler_reads_as_nil
    assert_nil(@xhr.__js_get__("onload"))
  end
end
