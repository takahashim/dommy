# frozen_string_literal: true

require_relative "test_helper"

# --- matchMedia / MediaQueryList ------------------------------------

class TestMatchMedia < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_returns_media_query_list
    mql = @win.__js_call__("matchMedia", ["(min-width: 600px)"])
    assert_kind_of(Dommy::MediaQueryList, mql)
    assert_equal("(min-width: 600px)", mql.media)
    refute(mql.matches)
  end

  def test_set_matches_dispatches_change_event
    mql = @win.__js_call__("matchMedia", ["(prefers-color-scheme: dark)"])
    fired = nil
    mql.add_event_listener("change", proc { |e| fired = e.matches })
    mql.__test_set_matches__(true)
    assert(mql.matches)
    assert_equal(true, fired)
  end

  def test_onchange_property_replaces_handler
    mql = @win.__js_call__("matchMedia", ["(orientation: portrait)"])
    first = nil
    second = nil
    mql.__js_set__("onchange", proc { |e| first = e.matches })
    mql.__js_set__("onchange", proc { |e| second = e.matches })
    mql.__test_set_matches__(true)
    assert_nil(first)
    assert_equal(true, second)
  end

  def test_legacy_add_listener
    mql = @win.__js_call__("matchMedia", ["(max-width: 800px)"])
    captured = nil
    mql.add_listener(proc { |e| captured = e.matches })
    mql.__test_set_matches__(true)
    assert_equal(true, captured)
  end
end

# --- structuredClone (global) ---------------------------------------

class TestStructuredCloneGlobal < Minitest::Test
  include DommyTestHelper

  def test_window_structured_clone
    win = make_window
    src = {"a" => 1, "b" => [2, 3]}
    cloned = win.__js_call__("structuredClone", [src])
    assert_equal(src, cloned)
    refute_same(src, cloned)
  end
end

# A virtual window scroll position (no real layout): scrollTo/scroll/scrollBy
# update it and a scroll event fires on change, so observers can record/replay
# the position (Turbo's scroll restoration).
class TestWindowScroll < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_initial_scroll_is_zero
    assert_equal(0, @win.__js_get__("scrollX"))
    assert_equal(0, @win.__js_get__("scrollY"))
    assert_equal(0, @win.__js_get__("pageYOffset"))
  end

  def test_scroll_to_sets_absolute_position
    @win.__js_call__("scrollTo", [0, 300])
    assert_equal(300, @win.__js_get__("scrollY"))
    assert_equal(300, @win.__js_get__("pageYOffset"))
    assert_equal(0, @win.__js_get__("scrollX"))
  end

  def test_scroll_by_is_relative
    @win.__js_call__("scrollTo", [0, 300])
    @win.__js_call__("scrollBy", [10, 50])
    assert_equal(10, @win.__js_get__("scrollX"))
    assert_equal(350, @win.__js_get__("scrollY"))
  end

  def test_scroll_to_options_dict
    @win.__js_call__("scrollTo", [{"left" => 5, "top" => 25}])
    assert_equal(5, @win.__js_get__("scrollX"))
    assert_equal(25, @win.__js_get__("scrollY"))
  end

  def test_scroll_event_fires_on_change_only
    count = 0
    @win.add_event_listener("scroll", proc { count += 1 })
    @win.__js_call__("scrollTo", [0, 100])
    @win.__js_call__("scrollTo", [0, 100]) # same position, no event
    @win.__js_call__("scrollTo", [0, 200])
    assert_equal(2, count)
  end
end

# --- requestIdleCallback --------------------------------------------

class TestRequestIdleCallback < Minitest::Test
  include DommyTestHelper

  def test_callback_runs_on_scheduler_advance
    win = make_window
    called = nil
    win.__js_call__("requestIdleCallback", [proc { |dl| called = dl }])
    win.scheduler.advance_time(0)
    refute_nil(called)
    assert(called["timeRemaining"] > 0)
  end

  def test_cancel_prevents_callback
    win = make_window
    called = false
    id = win.__js_call__("requestIdleCallback", [proc { called = true }])
    win.__js_call__("cancelIdleCallback", [id])
    win.scheduler.advance_time(0)
    refute(called)
  end
end

# --- FileReader -----------------------------------------------------

class TestFileReader < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @blob = Dommy::Blob.new(["hello"], "type" => "text/plain")
  end

  def test_read_as_text
    fr = Dommy::FileReader.new(@win)
    fr.read_as_text(@blob)
    @win.scheduler.drain_microtasks
    assert_equal("hello", fr.result)
    assert_equal(Dommy::FileReader::DONE, fr.ready_state)
  end

  def test_read_as_data_url
    fr = Dommy::FileReader.new(@win)
    fr.read_as_data_url(@blob)
    @win.scheduler.drain_microtasks
    assert_equal("data:text/plain;base64,aGVsbG8=", fr.result)
  end

  def test_read_as_array_buffer
    fr = Dommy::FileReader.new(@win)
    fr.read_as_array_buffer(@blob)
    @win.scheduler.drain_microtasks
    assert_equal([104, 101, 108, 108, 111], fr.result)
  end

  def test_load_event_fires
    fr = Dommy::FileReader.new(@win)
    fired = false
    fr.add_event_listener("load", proc { |_e| fired = true })
    fr.read_as_text(@blob)
    @win.scheduler.drain_microtasks
    assert(fired)
  end

  def test_abort_prevents_load
    fr = Dommy::FileReader.new(@win)
    loaded = false
    fr.add_event_listener("load", proc { |_e| loaded = true })
    fr.read_as_text(@blob)
    fr.abort
    @win.scheduler.drain_microtasks
    refute(loaded)
  end

  def test_window_exposes_constructor
    ctor = @win.__js_get__("FileReader")
    fr = ctor.__js_new__([])
    assert_kind_of(Dommy::FileReader, fr)
  end
end

# --- Notification ---------------------------------------------------

class TestNotification < Minitest::Test
  include DommyTestHelper

  def test_construction_stores_options
    win = make_window
    n = Dommy::Notification.new(win, "Hi", {"body" => "World", "tag" => "x"})
    assert_equal("Hi", n.title)
    assert_equal("World", n.body)
    assert_equal("x", n.tag)
  end

  def test_permission_default
    Dommy::Notification.__test_set_permission__("default")
    assert_equal("default", Dommy::Notification.permission)
  end

  def test_permission_can_be_set
    Dommy::Notification.__test_set_permission__("granted")
    assert_equal("granted", Dommy::Notification.permission)
    # reset
    Dommy::Notification.__test_set_permission__("default")
  end

  def test_close_fires_close_event
    win = make_window
    n = Dommy::Notification.new(win, "Hi")
    fired = false
    n.add_event_listener("close", proc { |_e| fired = true })
    n.close
    assert(fired)
  end

  def test_window_exposes_constructor
    win = make_window
    ctor = win.__js_get__("Notification")
    refute_nil(ctor)
  end
end

# --- Geolocation ----------------------------------------------------

class TestGeolocation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @geo = @win.navigator.geolocation
  end

  def test_get_current_position_returns_set_coords
    @geo.__test_set_position__("latitude" => 35.0, "longitude" => 139.0)
    pos = nil
    @geo.get_current_position(proc { |p| pos = p })
    @win.scheduler.drain_microtasks
    assert_equal(35.0, pos["coords"]["latitude"])
    assert_equal(139.0, pos["coords"]["longitude"])
  end

  def test_get_current_position_uses_error_callback
    @geo.__test_set_error__(1, "denied")
    err = nil
    @geo.get_current_position(
      proc { |_| flunk("should not succeed") },
      proc { |e| err = e }
    )
    @win.scheduler.drain_microtasks
    assert_equal(1, err["code"])
    assert_equal("denied", err["message"])
  end

  def test_watch_returns_id_and_clear_works
    @geo.__test_set_position__
    id = @geo.watch_position(proc { |_| })
    assert_kind_of(Integer, id)
    @geo.clear_watch(id)
  end
end

# --- MessageChannel / MessagePort -----------------------------------

class TestMessageChannel < Minitest::Test
  include DommyTestHelper

  def test_post_message_delivered_to_other_port
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    received = nil
    mc.port2.__js_set__("onmessage", proc { |e| received = e.data })
    mc.port1.post_message("hello")
    win.scheduler.drain_microtasks
    assert_equal("hello", received)
  end

  def test_complex_payload_structured_cloned
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    received = nil
    mc.port2.__js_set__("onmessage", proc { |e| received = e.data })
    src = {"k" => [1, 2, 3]}
    mc.port1.post_message(src)
    win.scheduler.drain_microtasks
    assert_equal(src, received)
    refute_same(src, received)
  end

  def test_window_exposes_constructor
    win = make_window
    ctor = win.__js_get__("MessageChannel")
    mc = ctor.__js_new__([])
    assert_kind_of(Dommy::MessageChannel, mc)
    assert_kind_of(Dommy::MessagePort, mc.port1)
  end
end

# --- BroadcastChannel ----------------------------------------------

class TestBroadcastChannel < Minitest::Test
  include DommyTestHelper

  def test_sends_to_peers_only
    win = make_window
    sender = Dommy::BroadcastChannel.new(win, "ch")
    peer = Dommy::BroadcastChannel.new(win, "ch")
    received = nil
    self_received = nil
    peer.add_event_listener("message", proc { |e| received = e.data })
    sender.add_event_listener("message", proc { |e| self_received = e.data })

    sender.post_message("ping")
    win.scheduler.drain_microtasks

    assert_equal("ping", received)
    # sender does not receive own messages
    assert_nil(self_received)
  end

  def test_close_unsubscribes
    win = make_window
    a = Dommy::BroadcastChannel.new(win, "x")
    b = Dommy::BroadcastChannel.new(win, "x")
    got = false
    b.add_event_listener("message", proc { |_| got = true })
    b.close
    a.post_message("hi")
    win.scheduler.drain_microtasks
    refute(got)
  end
end

# --- WebSocket ------------------------------------------------------

class TestWebSocket < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_auto_opens_via_microtask
    ws = Dommy::WebSocket.new(@win, "wss://x.test/")
    opened = false
    ws.add_event_listener("open", proc { |_| opened = true })
    @win.scheduler.drain_microtasks
    assert(opened)
    assert_equal(Dommy::WebSocket::OPEN, ws.ready_state)
  end

  def test_send_records_messages
    ws = Dommy::WebSocket.new(@win, "wss://x.test/")
    @win.scheduler.drain_microtasks
    ws.send("hello")
    ws.send("world")
    assert_equal(%w[hello world], ws.__test_sent_messages__)
  end

  def test_simulate_message_dispatches_event
    ws = Dommy::WebSocket.new(@win, "wss://x.test/")
    @win.scheduler.drain_microtasks
    received = nil
    ws.add_event_listener("message", proc { |e| received = e.data })
    ws.__test_simulate_message__("from server")
    assert_equal("from server", received)
  end

  def test_close_transitions_to_closed
    ws = Dommy::WebSocket.new(@win, "wss://x.test/")
    @win.scheduler.drain_microtasks
    closed = false
    ws.add_event_listener("close", proc { |e| closed = e.code })
    ws.close(1000, "bye")
    @win.scheduler.drain_microtasks
    assert_equal(1000, closed)
    assert_equal(Dommy::WebSocket::CLOSED, ws.ready_state)
  end

  def test_send_before_open_raises
    ws = Dommy::WebSocket.new(@win, "wss://x.test/")
    # send() before the connection opens is a spec InvalidStateError DOMException.
    assert_raises(Dommy::DOMException::InvalidStateError) { ws.send("too early") }
  end

  def test_window_exposes_constructor
    ctor = @win.__js_get__("WebSocket")
    ws = ctor.__js_new__(["wss://x.test/"])
    assert_kind_of(Dommy::WebSocket, ws)
  end
end

# --- EventSource ----------------------------------------------------

class TestEventSource < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_auto_opens
    es = Dommy::EventSource.new(@win, "/sse")
    opened = false
    es.add_event_listener("open", proc { |_| opened = true })
    @win.scheduler.drain_microtasks
    assert(opened)
    assert_equal(Dommy::EventSource::OPEN, es.ready_state)
  end

  def test_simulate_message_dispatches
    es = Dommy::EventSource.new(@win, "/sse")
    @win.scheduler.drain_microtasks
    payload = nil
    es.add_event_listener("message", proc { |e| payload = e.data })
    es.__test_simulate_message__("event-1")
    assert_equal("event-1", payload)
  end

  def test_custom_event_name
    es = Dommy::EventSource.new(@win, "/sse")
    @win.scheduler.drain_microtasks
    captured = nil
    es.add_event_listener("user-joined", proc { |e| captured = e.data })
    es.__test_simulate_message__("alice", event: "user-joined")
    assert_equal("alice", captured)
  end
end

# --- SubtleCrypto ---------------------------------------------------

class TestSubtleCrypto < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @subtle = @win.__js_get__("crypto").subtle
  end

  def test_sha256_known_vector
    bytes = @subtle.digest("SHA-256", "hello").await
    hex = bytes.map { |b| format("%02x", b) }.join
    assert_equal("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex)
  end

  def test_sha1_known_vector
    bytes = @subtle.digest("SHA-1", "abc").await
    hex = bytes.map { |b| format("%02x", b) }.join
    assert_equal("a9993e364706816aba3e25717850c26c9cd0d89d", hex)
  end

  def test_algorithm_accepts_hash
    bytes_a = @subtle.digest("SHA-256", "x").await
    bytes_b = @subtle.digest({"name" => "SHA-256"}, "x").await
    assert_equal(bytes_a, bytes_b)
  end

  def test_unsupported_algorithm_rejects
    assert_raises(ArgumentError) { @subtle.digest("MD5", "x").await }
  end

  def test_returns_promise_value
    assert_kind_of(Dommy::PromiseValue, @subtle.digest("SHA-256", "x"))
  end
end
