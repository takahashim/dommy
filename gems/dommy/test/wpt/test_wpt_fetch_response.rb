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
    # `.body` is a ReadableStream; the body content is read via text().
    r = Dommy::Response.new(@win, body: "hello")
    assert_equal("hello", r.__js_call__("text", []).await)
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

  # arrayBuffer() resolves to the body bytes as Array<Integer>,
  # matching FileReader#readAsArrayBuffer and Blob#arrayBuffer.
  def test_array_buffer_resolves_to_byte_array
    r = Dommy::Response.new(@win, body: "binary-ish")
    assert_equal("binary-ish".bytes, r.__js_call__("arrayBuffer", []).await)
  end

  # blob() resolves to a real Dommy::Blob whose bytes round-trip.
  def test_blob_resolves_to_blob_instance
    r = Dommy::Response.new(@win, body: "blob body")
    blob = r.__js_call__("blob", []).await
    assert_kind_of(Dommy::Blob, blob)
    assert_equal("blob body", blob.text)
  end

  # Blob inherits the Content-Type header as its MIME type.
  def test_blob_type_comes_from_content_type_header
    r = Dommy::Response.new(@win, body: "{}", headers: {"Content-Type" => "application/json"})
    blob = r.__js_call__("blob", []).await
    assert_equal("application/json", blob.type)
  end

  def test_blob_type_empty_without_content_type
    r = Dommy::Response.new(@win, body: "x")
    assert_equal("", r.__js_call__("blob", []).await.type)
  end
end

class TestWPTResponseConstructor < Minitest::Test
  # WPT: fetch/api/response/response-init-001/002.any.js
  # Spec: https://fetch.spec.whatwg.org/#dom-response

  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_status_out_of_range_raises_range_error
    assert_raises(Dommy::Bridge::RangeError) { Dommy::Response.__construct__(@win, "x", {"status" => 0}) }
    assert_raises(Dommy::Bridge::RangeError) { Dommy::Response.__construct__(@win, "x", {"status" => 600}) }
  end

  def test_null_body_status_with_body_raises_type_error
    [204, 205, 304].each do |status|
      assert_raises(Dommy::Bridge::TypeError, "status #{status} with body") do
        Dommy::Response.__construct__(@win, "body", {"status" => status})
      end
    end
  end

  def test_null_body_status_without_body_is_allowed
    r = Dommy::Response.__construct__(@win, nil, {"status" => 204})
    assert_equal(204, r.__js_get__("status"))
  end

  def test_default_content_type_for_non_null_body
    r = Dommy::Response.__construct__(@win, "hi", {})
    assert_equal("text/plain;charset=UTF-8", r.__js_get__("headers").__js_call__("get", ["Content-Type"]))
  end

  def test_array_buffer_is_byte_array
    r = Dommy::Response.new(@win, body: "AB")
    assert_equal([65, 66], r.__js_call__("arrayBuffer", []).await)
  end
end

class TestWPTResponseStatics < Minitest::Test
  # WPT: fetch/api/response/response-static-json.any.js,
  #      fetch/api/response/response-static-redirect.any.js,
  #      fetch/api/response/response-static-error.any.js
  # Spec: https://fetch.spec.whatwg.org/#response-class (static methods)

  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_json_serializes_data_and_sets_content_type
    r = Dommy::Response.__json__(@win, {"a" => 1})
    assert_equal('{"a":1}', r.__js_call__("text", []).await)
    assert_equal("application/json", r.__js_get__("headers").__js_call__("get", ["Content-Type"]))
    assert_equal(200, r.__js_get__("status"))
  end

  def test_json_honors_init_status_and_keeps_explicit_content_type
    r = Dommy::Response.__json__(@win, [1, 2], {"status" => 201, "headers" => {"Content-Type" => "application/problem+json"}})
    assert_equal(201, r.__js_get__("status"))
    assert_equal("application/problem+json", r.__js_get__("headers").__js_call__("get", ["content-type"]))
  end

  def test_json_null_body_status_raises_type_error
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Response.__json__(@win, {}, {"status" => 204}) }
  end

  def test_redirect_sets_location_and_status
    r = Dommy::Response.__redirect__(@win, "https://example.test/x", 301)
    assert_equal(301, r.__js_get__("status"))
    assert_equal("https://example.test/x", r.__js_get__("headers").__js_call__("get", ["Location"]))
  end

  def test_redirect_defaults_to_302
    assert_equal(302, Dommy::Response.__redirect__(@win, "/y").__js_get__("status"))
  end

  def test_redirect_invalid_status_raises_range_error
    assert_raises(Dommy::Bridge::RangeError) { Dommy::Response.__redirect__(@win, "/y", 200) }
  end

  # WHATWG: the url is parsed (resolved against the base) and the Location
  # header is the *serialized* parsed URL.
  def test_redirect_resolves_relative_url_against_base
    r = Dommy::Response.__redirect__(@win, "/path", 302)
    assert_equal("http://localhost/path", r.__js_get__("headers").__js_call__("get", ["Location"]))
  end

  def test_redirect_invalid_url_raises_type_error
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Response.__redirect__(@win, "http://", 302) }
  end

  def test_error_is_status_zero_not_ok
    r = Dommy::Response.__error__(@win)
    assert_equal(0, r.__js_get__("status"))
    refute(r.__js_get__("ok"))
  end

  # WHATWG: Response.json serializes the value; JS `undefined` is not
  # JSON-serializable and is a TypeError, while `null` becomes "null".
  def test_json_undefined_raises_type_error
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Response.__json__(@win, Dommy::Bridge::UNDEFINED) }
  end

  def test_json_null_serializes_to_null
    r = Dommy::Response.__json__(@win, nil)
    assert_equal("null", r.__js_call__("text", []).await)
  end

  def test_json_false_serializes
    r = Dommy::Response.__json__(@win, false)
    assert_equal("false", r.__js_call__("text", []).await)
  end
end

class TestWPTResponseImmutableHeaders < Minitest::Test
  # WHATWG: the headers of Response.error()/redirect() have an "immutable"
  # guard — any mutation raises a TypeError. A normal Response is mutable.

  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_error_headers_are_immutable
    headers = Dommy::Response.__error__(@win).__js_get__("headers")
    assert_raises(Dommy::Bridge::TypeError) { headers.__js_call__("set", ["X-A", "1"]) }
    assert_raises(Dommy::Bridge::TypeError) { headers.__js_call__("append", ["X-A", "1"]) }
    assert_raises(Dommy::Bridge::TypeError) { headers.__js_call__("delete", ["location"]) }
  end

  def test_redirect_headers_are_immutable
    headers = Dommy::Response.__redirect__(@win, "/x", 302).__js_get__("headers")
    assert_raises(Dommy::Bridge::TypeError) { headers.__js_call__("set", ["X-A", "1"]) }
  end

  def test_constructed_response_headers_are_mutable
    headers = Dommy::Response.__construct__(@win, "hi", {}).__js_get__("headers")
    headers.__js_call__("set", ["X-A", "1"]) # no raise
    assert_equal("1", headers.__js_call__("get", ["x-a"]))
  end
end

class TestWPTResponseStatusText < Minitest::Test
  # WHATWG: statusText must match the reason-phrase production (HTAB/SP/VCHAR/
  # obs-text); other control characters are a TypeError.

  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_valid_status_text_is_accepted
    r = Dommy::Response.__construct__(@win, "x", {"statusText" => "I'm a teapot"})
    assert_equal("I'm a teapot", r.__js_get__("statusText"))
  end

  def test_invalid_status_text_raises_type_error
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Response.__construct__(@win, "x", {"statusText" => "bad\r\n"}) }
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Response.__construct__(@win, "x", {"statusText" => "bad\x01ctl"}) }
  end

  def test_json_validates_status_text
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Response.__json__(@win, {}, {"statusText" => "x\n"}) }
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
    assert_equal("hi", clone.__js_call__("text", []).await)
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

class TestWPTResponseType < Minitest::Test
  # WHATWG: response.type — "default" (constructed), "error" (Response.error).
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_constructed_response_is_default
    assert_equal("default", Dommy::Response.__construct__(@win, "x", {}).__js_get__("type"))
    assert_equal("default", Dommy::Response.__json__(@win, {}).__js_get__("type"))
    assert_equal("default", Dommy::Response.__redirect__(@win, "/x", 302).__js_get__("type"))
  end

  def test_error_response_is_error_type
    assert_equal("error", Dommy::Response.__error__(@win).__js_get__("type"))
  end

  def test_clone_preserves_type
    assert_equal("error", Dommy::Response.__error__(@win).__js_call__("clone", []).__js_get__("type"))
  end
end

class TestWPTResponseBody < Minitest::Test
  # WHATWG: response.body is a ReadableStream (or null); bodyUsed tracks single
  # consumption; a second consume rejects; clone after consume throws.
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_body_is_a_readable_stream
    r = Dommy::Response.new(@win, body: "hi")
    assert_kind_of(Dommy::ReadableStream, r.__js_get__("body"))
  end

  def test_body_is_memoized_for_identity
    r = Dommy::Response.new(@win, body: "hi")
    assert_same(r.__js_get__("body"), r.__js_get__("body"))
  end

  def test_null_body_status_has_null_body
    r = Dommy::Response.__construct__(@win, nil, {"status" => 204})
    assert_nil(r.__js_get__("body"))
  end

  def test_no_arg_response_has_null_body
    assert_nil(Dommy::Response.__construct__(@win, nil, {}).__js_get__("body"))
  end

  def test_body_used_transitions_on_consume
    r = Dommy::Response.new(@win, body: "hi")
    refute(r.__js_get__("bodyUsed"))
    r.__js_call__("text", []).await
    assert(r.__js_get__("bodyUsed"))
  end

  def test_second_consume_rejects
    r = Dommy::Response.new(@win, body: "hi")
    r.__js_call__("text", []).await
    # A used body's consume returns a rejected promise (await raises).
    assert_raises(RuntimeError) { r.__js_call__("json", []).await }
  end

  def test_clone_after_consume_raises
    r = Dommy::Response.new(@win, body: "hi")
    r.__js_call__("text", []).await
    assert_raises(Dommy::Bridge::TypeError) { r.__js_call__("clone", []) }
  end
end

class TestWPTResponseBodyExtraction < Minitest::Test
  # WHATWG "extract a body": Blob/URLSearchParams/FormData/ArrayBuffer bodies
  # yield the right bytes and default Content-Type.
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def ct(response)
    response.__js_get__("headers").__js_call__("get", ["Content-Type"])
  end

  def test_blob_body_uses_its_bytes_and_type
    blob = Dommy::Blob.new(["hi there"], "type" => "text/markdown")
    r = Dommy::Response.__construct__(@win, blob, {})
    assert_equal("hi there", r.__js_call__("text", []).await)
    assert_equal("text/markdown", ct(r))
  end

  def test_typeless_blob_body_has_no_content_type
    r = Dommy::Response.__construct__(@win, Dommy::Blob.new(["x"]), {})
    assert_nil(ct(r))
  end

  def test_url_search_params_body
    usp = Dommy::URLSearchParams.new("a=1&b=2")
    r = Dommy::Response.__construct__(@win, usp, {})
    assert_equal("a=1&b=2", r.__js_call__("text", []).await)
    assert_equal("application/x-www-form-urlencoded;charset=UTF-8", ct(r))
  end

  def test_array_buffer_body_has_no_default_content_type
    bytes = Dommy::Bridge::Bytes.new("Hi".bytes)
    r = Dommy::Response.__construct__(@win, bytes, {})
    assert_equal("Hi", r.__js_call__("text", []).await)
    assert_nil(ct(r))
  end

  def test_form_data_body_is_multipart
    fd = Dommy::FormData.new
    fd.append("name", "alice")
    r = Dommy::Response.__construct__(@win, fd, {})
    assert(ct(r).start_with?("multipart/form-data; boundary="))
    body = r.__js_call__("text", []).await
    assert_includes(body, 'Content-Disposition: form-data; name="name"')
    assert_includes(body, "alice")
  end

  def test_explicit_content_type_overrides_extracted_default
    usp = Dommy::URLSearchParams.new("a=1")
    r = Dommy::Response.__construct__(@win, usp, {"headers" => {"Content-Type" => "text/plain"}})
    assert_equal("text/plain", ct(r))
  end
end
