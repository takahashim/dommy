# frozen_string_literal: true

require_relative "test_helper"

class TestRequest < Minitest::Test
  include DommyTestHelper

  def test_default_method_is_get
    req = Dommy::Request.new("/api")
    assert_equal("/api", req.url)
    assert_equal("GET", req.method)
  end

  def test_method_uppercased
    req = Dommy::Request.new("/api", "method" => "post")
    assert_equal("POST", req.method)
  end

  def test_init_options_are_reflected
    req = Dommy::Request.new(
      "/upload",
      "method" => "PUT",
      "body" => "hello",
      "headers" => {"Content-Type" => "text/plain"},
      "credentials" => "include",
      "mode" => "no-cors",
      "cache" => "no-store",
      "redirect" => "manual"
    )
    assert_equal("/upload", req.url)
    assert_equal("PUT", req.method)
    assert_equal("hello", req.body)
    assert_equal("include", req.credentials)
    assert_equal("no-cors", req.mode)
    assert_equal("no-store", req.cache)
    assert_equal("manual", req.redirect)
    # WHATWG Headers store names lowercased; look up via the case-insensitive get.
    assert_equal("text/plain", req.headers.__js_call__("get", ["Content-Type"]))
  end

  def test_js_bridge_get
    req = Dommy::Request.new("/x", "method" => "POST", "body" => "B")
    assert_equal("/x", req.__js_get__("url"))
    assert_equal("POST", req.__js_get__("method"))
    assert_equal("B", req.__js_get__("body"))
  end

  def test_clone_creates_new_instance
    req = Dommy::Request.new("/x", "method" => "POST", "body" => "B")
    cloned = req.__js_call__("clone", [])
    assert_kind_of(Dommy::Request, cloned)
    refute_same(req, cloned)
    assert_equal("POST", cloned.method)
    assert_equal("B", cloned.body)
  end

  # WHATWG: a Request always has an AbortSignal, even when none is passed —
  # `request.signal` must never be undefined. react-router reads
  # `request.signal.removeEventListener(...)` and crashed when it was.
  def test_request_always_has_a_signal
    req = Dommy::Request.new("/x")
    signal = req.__js_get__("signal")
    refute_nil(signal)
    refute_equal(Dommy::Bridge::ABSENT, signal)
    assert_kind_of(Dommy::AbortSignal, signal)
    assert_equal(false, signal.__js_get__("aborted"))
    # The crashing access path must work (no-op remove on a fresh signal).
    assert_nil(signal.__js_call__("removeEventListener", ["abort", proc {}]))
  end

  def test_provided_signal_is_exposed_verbatim
    controller = Dommy::AbortController.new
    sig = controller.__js_get__("signal")
    req = Dommy::Request.new("/x", "signal" => sig)
    assert_same(sig, req.__js_get__("signal"))
  end

  def test_clone_preserves_the_signal
    controller = Dommy::AbortController.new
    sig = controller.__js_get__("signal")
    req = Dommy::Request.new("/x", "signal" => sig)
    cloned = req.__js_call__("clone", [])
    assert_same(sig, cloned.__js_get__("signal"))
  end

  def test_window_exposes_request_constructor
    win = make_window
    ctor = win.__js_get__("Request")
    req = ctor.__js_new__(["/api", {"method" => "DELETE"}])
    assert_kind_of(Dommy::Request, req)
    assert_equal("DELETE", req.method)
  end
end
