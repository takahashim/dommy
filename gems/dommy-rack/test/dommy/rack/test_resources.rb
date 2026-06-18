# frozen_string_literal: true

require "test_helper"

# Dommy::Rack::Resources — the session-backed arm of the resources interface.
class Dommy::Rack::TestResources < Minitest::Test
  include RackTestHelper

  def app
    app_for(
      "GET /api" => [200, {"Content-Type" => "application/json"}, ['{"ok":true}']],
      "POST /api" => ->(req) { [201, {"Content-Type" => "text/plain"}, ["got #{req.body.read}"]] },
      "GET /whoami" => ->(req) { [200, {"Content-Type" => "text/plain"}, [req.cookies["token"].to_s]] },
      "GET /" => [200, {"Content-Type" => "text/html", "Set-Cookie" => "token=abc"}, ["<p>home</p>"]]
    )
  end

  def resources
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    Dommy::Rack::Resources.new(session)
  end

  def test_same_origin_get_is_served_by_the_app
    r = resources.get("/api")
    assert_equal 200, r.status
    assert_equal '{"ok":true}', r.body
    assert_equal "http://example.org/api", r.url
    assert r.success?
  end

  def test_request_forwards_method_and_body
    r = resources.request(method: "POST", url: "/api", body: "hello")
    assert_equal 201, r.status
    assert_equal "got hello", r.body
  end

  def test_shares_the_session_cookie_jar
    assert_equal "abc", resources.get("/whoami").body
  end

  def test_cross_origin_declines_with_nil
    assert_nil resources.get("https://cdn.example.com/x")
  end

  def test_open_session_serves_cross_origin
    # An `:open` session loads cross-origin subresources (browser parity); the
    # backend SSRF guard, not this gate, is the boundary. The cross-origin host is
    # served by the same app here, returning its JSON.
    session = Dommy::Rack::Session.new(app, enforce_same_origin: false, cross_origin_subresources: :open)
    session.visit("/")
    r = Dommy::Rack::Resources.new(session).get("https://cdn.example.com/api")
    assert_equal 200, r.status
    refute session.blocked_subresource_hosts.include?("cdn.example.com"),
      "open mode does not record a block to prompt for"
  end

  # --- Off-thread (async-network) path: #request_job ---

  def test_request_job_yields_the_same_response_as_request
    job = resources.request_job(method: "GET", url: "/api")
    refute_nil job

    r = job.call # what a network worker runs
    assert_equal 200, r.status
    assert_equal '{"ok":true}', r.body
    assert_equal "http://example.org/api", r.url
  end

  def test_request_job_declines_cross_origin_synchronously
    # The serve/decline decision is made on the page thread, before any handoff.
    assert_nil resources.request_job(method: "GET", url: "https://cdn.example.com/x")
  end

  def test_request_job_forwards_method_and_body
    r = resources.request_job(method: "POST", url: "/api", body: "hello").call
    assert_equal 201, r.status
    assert_equal "got hello", r.body
  end

  def test_request_job_shares_the_session_cookie_jar
    assert_equal "abc", resources.request_job(method: "GET", url: "/whoami").call.body
  end

  def test_request_job_thunk_runs_safely_on_a_worker_thread
    job = resources.request_job(method: "GET", url: "/api")
    result = nil
    Thread.new { result = job.call }.join

    assert_equal 200, result.status
    assert_equal '{"ok":true}', result.body
  end
end
