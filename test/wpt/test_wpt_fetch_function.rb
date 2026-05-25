# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the `fetch()` global.
# WPT: fetch/api/basic/request-headers.any.js,
#      fetch/api/basic/status.any.js,
#      fetch/api/basic/scheme-others.any.js
# Spec: https://fetch.spec.whatwg.org/#fetch-method
#
# Existing test/test_fetch_blob.rb covers Blob body propagation only.
# This file covers the Promise return value, stub-driven Response
# construction, status / statusText / 404 handling, and the
# `__fetch_count__` / `__last_url__` / `__last_init__` introspection
# globals that Dommy maintains for test convenience.

class TestWPTFetchPromise < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "ok body" }
    })
  end

  def test_returns_promise_value
    promise = @win.__js_call__("fetch", ["/ok"])
    assert_instance_of(Dommy::PromiseValue, promise)
  end

  def test_promise_resolves_to_response
    promise = @win.__js_call__("fetch", ["/ok"])
    response = promise.await
    assert_instance_of(Dommy::Response, response)
  end

  def test_response_body_matches_stub
    response = @win.__js_call__("fetch", ["/ok"]).await
    assert_equal("ok body", response.__js_get__("body"))
  end
end

class TestWPTFetchStatusHandling < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/ok" => { "status" => 200, "body" => "ok" },
      "/created" => { "status" => 201, "body" => "created", "statusText" => "Created" },
      "/not-found" => { "status" => 404, "body" => "missing", "statusText" => "Not Found" },
      "/server-err" => { "status" => 500, "body" => "boom" }
    })
  end

  def test_status_200_is_ok
    response = @win.__js_call__("fetch", ["/ok"]).await
    assert_equal(200, response.__js_get__("status"))
    assert(response.__js_get__("ok"))
  end

  def test_status_201_is_ok
    response = @win.__js_call__("fetch", ["/created"]).await
    assert_equal(201, response.__js_get__("status"))
    assert(response.__js_get__("ok"))
  end

  def test_status_text_propagates_from_stub
    response = @win.__js_call__("fetch", ["/created"]).await
    assert_equal("Created", response.__js_get__("statusText"))
  end

  def test_status_404_is_not_ok
    response = @win.__js_call__("fetch", ["/not-found"]).await
    assert_equal(404, response.__js_get__("status"))
    refute(response.__js_get__("ok"))
  end

  def test_status_500_is_not_ok
    response = @win.__js_call__("fetch", ["/server-err"]).await
    refute(response.__js_get__("ok"))
  end
end

class TestWPTFetchUnknownURL < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", { "/known" => { "status" => 200, "body" => "" } })
  end

  def test_unknown_url_resolves_to_404
    response = @win.__js_call__("fetch", ["/never-registered"]).await
    assert_equal(404, response.__js_get__("status"))
  end

  def test_unknown_url_has_not_found_status_text
    response = @win.__js_call__("fetch", ["/never-registered"]).await
    assert_equal("Not Found", response.__js_get__("statusText"))
  end

  def test_unknown_url_body_is_not_found_marker
    response = @win.__js_call__("fetch", ["/never-registered"]).await
    assert_equal("not found", response.__js_get__("body"))
  end
end

class TestWPTFetchIntrospection < Minitest::Test
  # Dommy maintains `__fetch_count__`, `__last_url__`, `__last_init__`,
  # `__last_body__` so tests can assert on fetch invocation shape
  # without intercepting at the JS level.

  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", { "/x" => { "status" => 200, "body" => "" } })
  end

  def test_fetch_count_starts_at_zero
    assert_equal(0, @win.globals["__fetch_count__"].to_i)
  end

  def test_fetch_count_increments_per_call
    @win.__js_call__("fetch", ["/x"])
    assert_equal(1, @win.globals["__fetch_count__"])
    @win.__js_call__("fetch", ["/x"])
    assert_equal(2, @win.globals["__fetch_count__"])
  end

  def test_last_url_records_most_recent_url
    @win.__js_call__("fetch", ["/x"])
    assert_equal("/x", @win.globals["__last_url__"])
  end

  def test_last_init_records_init_hash
    @win.__js_call__("fetch", ["/x", {"method" => "POST", "body" => "data"}])
    init = @win.globals["__last_init__"]
    assert_equal("POST", init["method"])
    assert_equal("data", init["body"])
  end

  def test_last_body_records_body_from_init
    @win.__js_call__("fetch", ["/x", {"body" => "hello"}])
    assert_equal("hello", @win.globals["__last_body__"])
  end
end

class TestWPTFetchDelay < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.__js_set__("__fetchy_stub__", {
      "/slow" => { "status" => 200, "body" => "later", "delay" => 500 }
    })
  end

  def test_delayed_response_does_not_invoke_then_before_advance_time
    # Without advancing time past `delay: 500`, the fetch timer has
    # not fired, so a `then` handler attached to the promise is not
    # invoked.
    promise = @win.__js_call__("fetch", ["/slow"])
    invoked = false
    promise.__js_call__("then", [proc { |_r| invoked = true }])
    @win.scheduler.drain_microtasks
    refute(invoked)
  end

  def test_delayed_response_resolves_after_advance_time
    promise = @win.__js_call__("fetch", ["/slow"])
    @win.scheduler.advance_time(600)
    response = promise.await
    assert_equal("later", response.__js_get__("body"))
  end
end
