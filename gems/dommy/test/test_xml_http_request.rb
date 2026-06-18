# frozen_string_literal: true

require_relative "test_helper"

class TestXMLHttpRequest < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    install_stub(
      "/api/foo" => {
        "status" => 200,
        "body" => "hello world",
        "contentType" => "text/plain"
      },
      "/api/json" => {
        "status" => 200,
        "body" => "{\"name\":\"alice\",\"age\":30}",
        "contentType" => "application/json"
      },
      "/api/err" => {
        "status" => 500,
        "statusText" => "Internal Error",
        "body" => "boom"
      },
      "/api/slow" => {"status" => 200, "body" => "eventually", "delay" => 200}
    )
  end

  def install_stub(map)
    @win.__js_set__("__fetchy_stub__", map)
  end

  def new_xhr
    Dommy::XMLHttpRequest.new(@win)
  end

  # --- Constructor / constants ------------------------------------

  def test_ready_state_constants_match_spec
    assert_equal(0, Dommy::XMLHttpRequest::UNSENT)
    assert_equal(1, Dommy::XMLHttpRequest::OPENED)
    assert_equal(2, Dommy::XMLHttpRequest::HEADERS_RECEIVED)
    assert_equal(3, Dommy::XMLHttpRequest::LOADING)
    assert_equal(4, Dommy::XMLHttpRequest::DONE)
  end

  def test_constants_exposed_via_js_get
    xhr = new_xhr
    assert_equal(0, xhr.__js_get__("UNSENT"))
    assert_equal(4, xhr.__js_get__("DONE"))
  end

  def test_initial_ready_state_is_unsent
    assert_equal(0, new_xhr.ready_state)
  end

  # --- Sync requests ----------------------------------------------

  def test_sync_get_populates_response
    xhr = new_xhr
    xhr.open("GET", "/api/foo", false)
    xhr.send
    assert_equal(4, xhr.ready_state)
    assert_equal(200, xhr.status)
    assert_equal("hello world", xhr.response_text)
  end

  def test_sync_missing_url_returns_404
    xhr = new_xhr
    xhr.open("GET", "/missing", false)
    xhr.send
    assert_equal(404, xhr.status)
    assert_equal("Not Found", xhr.status_text)
  end

  # A `data:` URI resolves to its decoded payload (note.com loads icon SVGs as
  # `data:image/svg+xml;base64,…` via XHR — a 404 there broke its SVG components).
  def test_base64_data_uri_decodes_to_200
    xhr = new_xhr
    svg = "<svg width=\"24\"></svg>"
    xhr.open("GET", "data:image/svg+xml;base64,#{[svg].pack("m0")}", false)
    xhr.send
    assert_equal(200, xhr.status)
    assert_equal(svg, xhr.response_text)
  end

  def test_plain_data_uri_percent_decodes
    xhr = new_xhr
    xhr.open("GET", "data:text/plain,Hello%2C%20World", false)
    xhr.send
    assert_equal(200, xhr.status)
    assert_equal("Hello, World", xhr.response_text)
  end

  def test_sync_server_error_status
    xhr = new_xhr
    xhr.open("GET", "/api/err", false)
    xhr.send
    assert_equal(500, xhr.status)
    assert_equal("Internal Error", xhr.status_text)
  end

  # --- Async requests ---------------------------------------------

  def test_async_request_pending_until_drain
    xhr = new_xhr
    xhr.open("GET", "/api/foo")
    xhr.send
    assert_equal(1, xhr.ready_state)

    @win.scheduler.drain_microtasks
    assert_equal(4, xhr.ready_state)
    assert_equal("hello world", xhr.response_text)
  end

  def test_async_fires_state_transitions
    xhr = new_xhr
    states = []
    xhr.add_event_listener("readystatechange", proc { |_e| states << xhr.ready_state })
    xhr.open("GET", "/api/foo")
    xhr.send
    @win.scheduler.drain_microtasks
    assert_equal([1, 2, 3, 4], states)
  end

  def test_async_load_event_fires_on_completion
    xhr = new_xhr
    fired = []
    xhr.add_event_listener("load", proc { |_e| fired << :load })
    xhr.add_event_listener("loadend", proc { |_e| fired << :loadend })
    xhr.open("GET", "/api/foo")
    xhr.send
    @win.scheduler.drain_microtasks
    assert_equal(%i[load loadend], fired)
  end

  def test_async_delivery_with_delay_uses_scheduler
    xhr = new_xhr
    xhr.open("GET", "/api/slow")
    xhr.send
    assert_equal(1, xhr.ready_state)

    @win.scheduler.advance_time(199)
    assert_equal(1, xhr.ready_state)

    @win.scheduler.advance_time(1)
    assert_equal(4, xhr.ready_state)
    assert_equal("eventually", xhr.response_text)
  end

  # --- responseType decoding --------------------------------------

  def test_response_type_json_parses_body
    xhr = new_xhr
    xhr.response_type = "json"
    xhr.open("GET", "/api/json", false)
    xhr.send
    assert_equal({"name" => "alice", "age" => 30}, xhr.response)
    # responseText keeps the raw form.
    assert_equal("{\"name\":\"alice\",\"age\":30}", xhr.response_text)
  end

  def test_response_type_text_returns_string
    xhr = new_xhr
    xhr.response_type = "text"
    xhr.open("GET", "/api/foo", false)
    xhr.send
    assert_equal("hello world", xhr.response)
  end

  def test_response_type_arraybuffer_returns_byte_array
    xhr = new_xhr
    xhr.response_type = "arraybuffer"
    xhr.open("GET", "/api/foo", false)
    xhr.send
    # responseType "arraybuffer" yields an ArrayBuffer (crosses as a bare one).
    assert_kind_of(Dommy::Bridge::ArrayBuffer, xhr.response)
    assert_equal("hello world".bytes, xhr.response)
  end

  def test_response_type_blob_returns_blob_with_content_type
    xhr = new_xhr
    xhr.response_type = "blob"
    xhr.open("GET", "/api/foo", false)
    xhr.send
    assert_kind_of(Dommy::Blob, xhr.response)
    assert_equal("hello world", xhr.response.text)
    assert_equal("text/plain", xhr.response.type)
  end

  # --- Request headers --------------------------------------------

  def test_set_request_header_records_value
    xhr = new_xhr
    xhr.open("POST", "/api/foo", false)
    xhr.set_request_header("X-Auth", "token")
    # appended per spec
    xhr.set_request_header("X-Auth", "second")
    xhr.send("payload")

    assert_equal("payload", @win.__js_get__("__last_body__"))
  end

  def test_set_request_header_before_open_raises
    xhr = new_xhr
    assert_raises(Dommy::XMLHttpRequest::Error) { xhr.set_request_header("X-A", "1") }
  end

  # --- Response headers -------------------------------------------

  def test_get_response_header_case_insensitive
    install_stub(
      "/h" => {
        "status" => 200,
        "body" => "ok",
        "headers" => {"X-Custom" => "v1"}
      }
    )
    xhr = new_xhr
    xhr.open("GET", "/h", false)
    xhr.send
    assert_equal("v1", xhr.get_response_header("x-custom"))
    assert_equal("v1", xhr.get_response_header("X-Custom"))
  end

  def test_get_all_response_headers_serializes
    install_stub(
      "/h" => {
        "status" => 200,
        "body" => "ok",
        "headers" => {"X-One" => "1", "X-Two" => "2"}
      }
    )
    xhr = new_xhr
    xhr.open("GET", "/h", false)
    xhr.send
    text = xhr.get_all_response_headers
    assert_match(/X-One: 1\r\n/, text)
    assert_match(/X-Two: 2\r\n/, text)
  end

  # --- Abort -------------------------------------------------------

  def test_abort_resets_state_and_fires_event
    xhr = new_xhr
    aborted = false
    xhr.add_event_listener("abort", proc { |_e| aborted = true })
    xhr.open("GET", "/api/foo")
    xhr.send
    xhr.abort
    assert(aborted)
    assert_equal(0, xhr.ready_state)
  end

  def test_abort_prevents_completion_callback
    xhr = new_xhr
    load_fired = false
    xhr.add_event_listener("load", proc { |_e| load_fired = true })
    xhr.open("GET", "/api/foo")
    xhr.send
    xhr.abort
    @win.scheduler.drain_microtasks
    refute(load_fired)
  end

  # --- Inline `on*` handlers --------------------------------------

  def test_onload_property_sets_handler
    xhr = new_xhr
    fired = false
    xhr.__js_set__("onload", proc { |_e| fired = true })
    xhr.open("GET", "/api/foo")
    xhr.send
    @win.scheduler.drain_microtasks
    assert(fired)
  end

  def test_onload_property_replaces_previous_handler
    xhr = new_xhr
    first = false
    second = false
    xhr.__js_set__("onload", proc { |_e| first = true })
    xhr.__js_set__("onload", proc { |_e| second = true })
    xhr.open("GET", "/api/foo")
    xhr.send
    @win.scheduler.drain_microtasks
    refute(first)
    assert(second)
  end

  # --- Globals tracking (shared with FetchFn) ---------------------

  def test_send_increments_fetch_count
    xhr = new_xhr
    xhr.open("GET", "/api/foo", false)
    xhr.send
    assert_equal(1, @win.globals["__fetch_count__"])
    # open() resolves the URL against the document base before the request.
    assert_equal("http://localhost/api/foo", @win.globals["__last_url__"])
    assert_equal("GET", @win.globals["__last_method__"])
  end

  # --- Window-level constructor wiring ----------------------------

  def test_window_exposes_xmlhttprequest_constructor
    ctor = @win.__js_get__("XMLHttpRequest")
    refute_nil(ctor)
    xhr = ctor.__js_new__([])
    assert_kind_of(Dommy::XMLHttpRequest, xhr)
  end
end
