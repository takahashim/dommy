# frozen_string_literal: true

require_relative "test_helper"

# Covers the `__fetch_handler__` seam: a callable installed in window
# globals that resolves fetch/XHR requests before the stub maps are
# consulted (the hook dommy-rack's NetworkBridge plugs into).
class TestFetchHandler < Minitest::Test
  include DommyTestHelper

  class RecordingHandler
    attr_reader :calls

    def initialize(entries)
      @entries = entries
      @calls = []
    end

    def call(url, init)
      @calls << [url, init]
      @entries[url]
    end
  end

  def setup
    @win = make_window
    # The request URL is resolved against the document base before it reaches
    # the handler, so the handler is keyed by the absolute URL.
    @handler = RecordingHandler.new(
      "http://localhost/app" => {"status" => 201, "body" => "from handler", "headers" => {"Content-Type" => "text/plain"}}
    )
    @win.globals["__fetch_handler__"] = @handler
    # A stub may still be keyed by path; it matches the resolved URL's path.
    @win.globals["__fetchy_stub__"] = {"/stubbed" => {"status" => 200, "body" => "from stub"}}
  end

  def test_fetch_resolves_through_the_handler
    response = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/app", {"method" => "POST", "body" => "data"}]).await

    assert_equal 201, response.__js_get__("status")
    assert_equal "from handler", response.__js_call__("text", []).await
    url, init = @handler.calls.last
    assert_equal "http://localhost/app", url
    assert_equal "POST", init["method"]
    assert_equal "data", init["body"]
  end

  def test_fetch_falls_through_to_stub_when_handler_declines
    response = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/stubbed", nil]).await

    assert_equal "from stub", response.__js_call__("text", []).await
    assert_equal "http://localhost/stubbed", @handler.calls.last.first
  end

  def test_xhr_resolves_through_the_handler_with_request_init
    xhr = Dommy::XMLHttpRequest.new(@win)
    xhr.open("POST", "/app", false)
    xhr.set_request_header("X-Token", "t1")
    xhr.send("payload")

    assert_equal 201, xhr.__js_get__("status")
    assert_equal "from handler", xhr.__js_get__("responseText")
    url, init = @handler.calls.last
    assert_equal "http://localhost/app", url
    assert_equal "POST", init["method"]
    assert_equal "payload", init["body"]
    assert_equal "t1", init["headers"]["X-Token"]
  end

  def test_xhr_falls_through_to_stub_when_handler_declines
    xhr = Dommy::XMLHttpRequest.new(@win)
    xhr.open("GET", "/stubbed", false)
    xhr.send

    assert_equal "from stub", xhr.__js_get__("responseText")
  end
end
