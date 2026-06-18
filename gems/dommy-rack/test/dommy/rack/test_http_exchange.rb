# frozen_string_literal: true

require "test_helper"

# The pure request primitive the redirect loop issues per hop. It must touch only
# its injected (thread-safe / immutable) collaborators and route per-request
# observation through the on_request / on_response hooks, so the same exchange can
# run on a network worker thread for the async-network path.
class Dommy::Rack::TestHttpExchange < Minitest::Test
  def setup
    @config = Dommy::Rack::Session::Config.new(
      default_host: "http://example.org",
      user_agent: "DommyRack",
      accept: "*/*"
    ).freeze
    @jar = Dommy::Rack::CookieJar.new
    @headers = Dommy::Rack::HeaderStore.new
  end

  # A minimal Rack app that records the env it saw and returns a fixed response.
  def app(status: 200, response_headers: {"Content-Type" => "text/html"}, body: ["ok"], &capture)
    lambda do |env|
      capture&.call(env)
      [status, response_headers, body]
    end
  end

  def build(app, on_request: nil, on_response: nil)
    Dommy::Rack::HttpExchange.new(
      app: app, config: @config, cookie_jar: @jar, headers: @headers,
      on_request: on_request, on_response: on_response
    )
  end

  def test_performs_the_request_and_returns_a_response
    seen = nil
    response = build(app { |env| seen = env }).request("GET", "http://example.org/posts")

    assert_equal 200, response.status
    assert_equal "ok", response.body
    assert_equal "/posts", seen["PATH_INFO"]
  end

  def test_merges_persistent_headers_with_per_request_overrides
    @headers.set("X-Default", "kept")
    @headers.set("X-Override", "old")
    seen = nil
    build(app { |env| seen = env }).request(
      "GET", "http://example.org/", headers: {"X-Override" => "new"}
    )

    assert_equal "kept", seen["HTTP_X_DEFAULT"]
    assert_equal "new", seen["HTTP_X_OVERRIDE"]
  end

  def test_sends_stored_cookies_and_stores_set_cookie
    @jar.store_from_header("session=abc", "http://example.org/")
    seen = nil
    exchange = build(
      app(response_headers: {"Content-Type" => "text/html", "Set-Cookie" => "fresh=1"}) { |env| seen = env }
    )

    exchange.request("GET", "http://example.org/")

    assert_equal "session=abc", seen["HTTP_COOKIE"]
    assert_equal "1", @jar.get("fresh") # response cookie landed in the jar
  end

  def test_fires_observation_hooks_in_order_around_the_app_call
    order = []
    on_request = ->(env) { order << [:request, env["PATH_INFO"]] }
    on_response = ->(resp) { order << [:response, resp.status] }
    build(app { order << :app }, on_request: on_request, on_response: on_response)
      .request("GET", "http://example.org/x")

    assert_equal [[:request, "/x"], :app, [:response, 200]], order
  end

  def test_works_with_a_plain_header_snapshot_hash
    # The worker path passes a captured Hash instead of the live HeaderStore.
    seen = nil
    exchange = Dommy::Rack::HttpExchange.new(
      app: app { |env| seen = env }, config: @config, cookie_jar: @jar,
      headers: {"X-Snapshot" => "v"}
    )
    exchange.request("GET", "http://example.org/")

    assert_equal "v", seen["HTTP_X_SNAPSHOT"]
  end
end
