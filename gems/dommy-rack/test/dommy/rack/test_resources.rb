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
end
