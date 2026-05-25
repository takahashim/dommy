# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Fetch API Response.
# WPT: fetch/api/response/response-init-001.any.js,
#      fetch/api/response/response-consume-empty.any.js,
#      fetch/api/response/response-clone.any.js
# Spec: https://fetch.spec.whatwg.org/#response-class
#
# No existing test file targets Response directly; this fills the gap.
class TestWPTResponseProperties < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_status_defaults_to_200
    r = Dommy::Response.new(@win, body: "")
    assert_equal(200, r.__js_get__("status"))
  end

  def test_status_reflects_initializer
    r = Dommy::Response.new(@win, body: "", status: 404)
    assert_equal(404, r.__js_get__("status"))
  end

  def test_status_text_reflects_initializer
    r = Dommy::Response.new(@win, body: "", status: 200, status_text: "OK")
    assert_equal("OK", r.__js_get__("statusText"))
  end

  def test_url_reflects_initializer
    r = Dommy::Response.new(@win, body: "", url: "https://example.test/")
    assert_equal("https://example.test/", r.__js_get__("url"))
  end

  def test_body_reflects_initializer
    r = Dommy::Response.new(@win, body: "hello")
    assert_equal("hello", r.__js_get__("body"))
  end
end

class TestWPTResponseOkFlag < Minitest::Test
  # Spec: ok is true iff status is in the [200, 299] range.

  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_ok_true_for_status_200
    assert(Dommy::Response.new(@win, body: "", status: 200).__js_get__("ok"))
  end

  def test_ok_true_for_status_299
    assert(Dommy::Response.new(@win, body: "", status: 299).__js_get__("ok"))
  end

  def test_ok_false_for_status_300
    refute(Dommy::Response.new(@win, body: "", status: 300).__js_get__("ok"))
  end

  def test_ok_false_for_status_199
    refute(Dommy::Response.new(@win, body: "", status: 199).__js_get__("ok"))
  end

  def test_ok_false_for_status_404
    refute(Dommy::Response.new(@win, body: "", status: 404).__js_get__("ok"))
  end

  def test_ok_false_for_status_500
    refute(Dommy::Response.new(@win, body: "", status: 500).__js_get__("ok"))
  end
end

class TestWPTResponseBodyConsumption < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_text_resolves_with_body_string
    r = Dommy::Response.new(@win, body: "hello world")
    assert_equal("hello world", r.__js_call__("text", []).await)
  end

  def test_json_resolves_with_parsed_object
    r = Dommy::Response.new(@win, body: '{"name":"alice","age":30}')
    assert_equal({"name" => "alice", "age" => 30}, r.__js_call__("json", []).await)
  end

  def test_json_resolves_with_parsed_array
    r = Dommy::Response.new(@win, body: "[1, 2, 3]")
    assert_equal([1, 2, 3], r.__js_call__("json", []).await)
  end

  def test_json_rejects_for_invalid_json
    r = Dommy::Response.new(@win, body: "not json")
    promise = r.__js_call__("json", [])
    # PromiseValue#await raises RuntimeError for a rejected promise,
    # with the rejection value (an ErrorValue) wrapped in the message.
    assert_raises(RuntimeError) { promise.await }
  end

  def test_array_buffer_returns_body
    r = Dommy::Response.new(@win, body: "binary-ish")
    assert_equal("binary-ish", r.__js_call__("arrayBuffer", []).await)
  end

  def test_blob_returns_body
    r = Dommy::Response.new(@win, body: "blob body")
    assert_equal("blob body", r.__js_call__("blob", []).await)
  end
end

class TestWPTResponseClone < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_clone_returns_new_instance
    original = Dommy::Response.new(@win, body: "hi")
    clone = original.__js_call__("clone", [])
    refute_same(original, clone)
  end

  def test_clone_preserves_body
    original = Dommy::Response.new(@win, body: "hi")
    clone = original.__js_call__("clone", [])
    assert_equal("hi", clone.__js_get__("body"))
  end

  def test_clone_preserves_status_and_status_text
    original = Dommy::Response.new(@win, body: "", status: 418, status_text: "I'm a teapot")
    clone = original.__js_call__("clone", [])
    assert_equal(418, clone.__js_get__("status"))
    assert_equal("I'm a teapot", clone.__js_get__("statusText"))
  end

  def test_clone_preserves_url
    original = Dommy::Response.new(@win, body: "", url: "https://example.test/x")
    clone = original.__js_call__("clone", [])
    assert_equal("https://example.test/x", clone.__js_get__("url"))
  end

  def test_clone_preserves_headers
    original = Dommy::Response.new(
      @win, body: "", headers: {"Content-Type" => "application/json", "X-Foo" => "bar"}
    )
    clone = original.__js_call__("clone", [])
    clone_headers = clone.__js_get__("headers")
    assert_equal("application/json", clone_headers.__js_call__("get", ["Content-Type"]))
    assert_equal("bar", clone_headers.__js_call__("get", ["X-Foo"]))
  end
end
