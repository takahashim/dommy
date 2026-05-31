# frozen_string_literal: true

require_relative "test_helper"

# Audits WebSocket / MessageEvent / PopStateEvent / CloseEvent against the spec,
# including the surface frameworks rarely touch (close-code validation,
# binaryType enum, send-before-open, subprotocol negotiation, init dicts).
class TestWebSocketSpec < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    # Disable auto-open so CONNECTING-state behaviour is observable.
    @win.__js_set__("__ws_auto_open__", false)
  end

  def ws(url = "ws://localhost/socket", protocols = nil)
    Dommy::WebSocket.new(@win, url, protocols)
  end

  # --- construction / attributes -------------------------------------

  def test_initial_state_is_connecting
    assert_equal(Dommy::WebSocket::CONNECTING, ws.ready_state)
    assert_equal(0, ws.__js_get__("readyState"))
  end

  def test_url_and_defaults
    s = ws("ws://example/chat")
    assert_equal("ws://example/chat", s.url)
    assert_equal("blob", s.binary_type)
    assert_equal(0, s.buffered_amount)
    assert_equal("", s.extensions)
  end

  def test_ready_state_constants_on_instance
    s = ws
    assert_equal(0, s.__js_get__("CONNECTING"))
    assert_equal(1, s.__js_get__("OPEN"))
    assert_equal(2, s.__js_get__("CLOSING"))
    assert_equal(3, s.__js_get__("CLOSED"))
  end

  # --- subprotocol negotiation ---------------------------------------

  def test_protocol_is_empty_until_open
    s = ws("ws://x/", "chat")
    assert_equal("", s.protocol)
    s.__test_simulate_open__
    assert_equal("chat", s.protocol)
  end

  def test_protocol_selects_first_of_array
    s = ws("ws://x/", %w[v1 v2])
    s.__test_simulate_open__
    assert_equal("v1", s.protocol)
  end

  # --- binaryType enum reflection ------------------------------------

  def test_binary_type_accepts_valid_values
    s = ws
    s.__js_set__("binaryType", "arraybuffer")
    assert_equal("arraybuffer", s.binary_type)
    s.__js_set__("binaryType", "blob")
    assert_equal("blob", s.binary_type)
  end

  def test_binary_type_ignores_invalid_values
    s = ws
    s.__js_set__("binaryType", "junk")
    assert_equal("blob", s.binary_type)
  end

  # --- send -----------------------------------------------------------

  def test_send_before_open_raises_invalid_state
    s = ws
    err = assert_raises(Dommy::DOMException::InvalidStateError) { s.send("hi") }
    assert_equal("InvalidStateError", err.name)
  end

  def test_send_when_open_buffers_message
    s = ws
    s.__test_simulate_open__
    s.send("hello")
    assert_equal(["hello"], s.__test_sent_messages__)
  end

  # --- close validation ----------------------------------------------

  def test_close_with_no_args_is_allowed
    s = ws
    s.__test_simulate_open__
    s.close
    assert_equal(Dommy::WebSocket::CLOSING, s.ready_state)
  end

  def test_close_accepts_1000_and_3000_to_4999
    [1000, 3000, 4000, 4999].each do |code|
      s = ws
      s.__test_simulate_open__
      s.close(code)
      assert_equal(Dommy::WebSocket::CLOSING, s.ready_state, "code #{code}")
    end
  end

  def test_close_rejects_invalid_code
    s = ws
    s.__test_simulate_open__
    [42, 999, 1001, 2999, 5000].each do |code|
      assert_raises(Dommy::DOMException::InvalidAccessError, "code #{code}") { s.close(code) }
    end
  end

  def test_close_rejects_overlong_reason
    s = ws
    s.__test_simulate_open__
    assert_raises(Dommy::DOMException::SyntaxError) { s.close(1000, "x" * 124) }
  end

  def test_close_allows_123_byte_reason
    s = ws
    s.__test_simulate_open__
    s.close(1000, "x" * 123)
    assert_equal(Dommy::WebSocket::CLOSING, s.ready_state)
  end

  # --- events ---------------------------------------------------------

  def test_open_event_fires_and_sets_open_state
    s = ws
    fired = false
    s.add_event_listener("open", proc { fired = true })
    s.__test_simulate_open__
    assert(fired)
    assert_equal(Dommy::WebSocket::OPEN, s.ready_state)
  end

  def test_message_event_carries_data
    s = ws
    s.__test_simulate_open__
    seen = nil
    s.add_event_listener("message", proc { |e| seen = e.data })
    s.__test_simulate_message__("payload")
    assert_equal("payload", seen)
  end

  def test_close_event_carries_code_reason_wasclean
    s = ws
    s.__test_simulate_open__
    e = nil
    s.add_event_listener("close", proc { |ev| e = ev })
    s.__test_simulate_close__(1001, "going away", was_clean: false)
    assert_instance_of(Dommy::CloseEvent, e)
    assert_equal(1001, e.code)
    assert_equal("going away", e.reason)
    assert_equal(false, e.was_clean)
    assert_equal(Dommy::WebSocket::CLOSED, s.ready_state)
  end

  def test_onmessage_handler_property
    s = ws
    s.__test_simulate_open__
    seen = nil
    s.__js_set__("onmessage", proc { |e| seen = e.data })
    s.__test_simulate_message__("via-handler")
    assert_equal("via-handler", seen)
  end
end

class TestMessageEvent < Minitest::Test
  def msg(type = "message", init = nil)
    Dommy::MessageEvent.new(type, init)
  end

  def test_defaults
    e = msg
    assert_nil(e.data)
    assert_equal("", e.origin)
    assert_equal("", e.last_event_id)
    assert_nil(e.source)
    assert_equal([], e.ports)
    assert_equal("message", e.__js_get__("type"))
  end

  def test_init_dict
    e = msg("m", "data" => {"x" => 1}, "origin" => "http://x", "lastEventId" => "7")
    assert_equal({"x" => 1}, e.data)
    assert_equal("http://x", e.origin)
    assert_equal("7", e.last_event_id)
  end

  def test_is_event_subclass
    assert_kind_of(Dommy::Event, msg)
  end

  def test_init_message_event_sets_fields
    e = msg("x")
    e.__js_call__("initMessageEvent", ["greet", false, false, "hi", "http://o", "9"])
    assert_equal("greet", e.__js_get__("type"))
    assert_equal("hi", e.data)
    assert_equal("http://o", e.origin)
    assert_equal("9", e.last_event_id)
  end

  def test_init_message_event_requires_type
    assert_raises(Dommy::Bridge::TypeError) { msg.__js_call__("initMessageEvent", []) }
  end
end

class TestPopStateEvent < Minitest::Test
  def pop(type = "popstate", init = nil)
    Dommy::PopStateEvent.new(type, init)
  end

  def test_state_default_is_nil
    assert_nil(pop.state)
    assert_nil(pop.__js_get__("state"))
  end

  def test_state_from_init
    e = pop("popstate", "state" => {"a" => 1})
    assert_equal({"a" => 1}, e.state)
  end

  def test_is_event_not_custom_event
    assert_kind_of(Dommy::Event, pop)
    refute_kind_of(Dommy::CustomEvent, pop)
  end
end

class TestCloseEvent < Minitest::Test
  def test_defaults
    e = Dommy::CloseEvent.new("close")
    assert_equal(1005, e.code)
    assert_equal("", e.reason)
    assert_equal(false, e.was_clean)
  end

  def test_init_dict
    e = Dommy::CloseEvent.new("close", "code" => 1000, "reason" => "bye", "wasClean" => true)
    assert_equal(1000, e.code)
    assert_equal("bye", e.reason)
    assert_equal(true, e.was_clean)
    assert_equal(1000, e.__js_get__("code"))
  end
end
