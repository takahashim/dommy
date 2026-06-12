# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestNetworkBridge < Minitest::Test
  include RackTestHelper

  def app
    app_for(
      "GET /" => [200, {"Content-Type" => "text/html", "Set-Cookie" => "token=abc"}, ["<p>home</p>"]],
      "GET /api" => [200, {"Content-Type" => "application/json"}, ['{"ok":true}']],
      "POST /api" => ->(req) { [201, {"Content-Type" => "text/plain"}, ["got #{req.body.read}"]] },
      "GET /whoami" => ->(req) { [200, {"Content-Type" => "text/plain"}, [req.cookies["token"].to_s]] }
    )
  end

  def bridged_session
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    window = session.document.default_view
    Dommy::Rack::NetworkBridge.install(session, window)
    [session, window]
  end

  def js_fetch(window, url, init = nil)
    Dommy::FetchFn.new(window).__js_call__("fetch", [url, init]).await
  end

  def test_same_origin_fetch_is_served_by_the_app
    _session, window = bridged_session
    response = js_fetch(window, "/api")

    assert_equal 200, response.__js_get__("status")
    assert_equal '{"ok":true}', response.__js_call__("text", []).await
    assert_equal "http://example.org/api", response.__js_get__("url")
  end

  def test_method_and_body_are_forwarded
    _session, window = bridged_session
    response = js_fetch(window, "/api", {"method" => "POST", "body" => "hello"})

    assert_equal 201, response.__js_get__("status")
    assert_equal "got hello", response.__js_call__("text", []).await
  end

  def test_fetch_shares_the_session_cookie_jar
    _session, window = bridged_session
    response = js_fetch(window, "/whoami")

    assert_equal "abc", response.__js_call__("text", []).await
  end

  def test_fetch_does_not_change_the_current_document
    session, window = bridged_session
    js_fetch(window, "/api")

    assert_equal "/", session.current_path
    assert_equal "home", session.document.body.text_content.strip
  end

  def test_cross_origin_urls_fall_through_to_stubs
    _session, window = bridged_session
    window.globals["__fetchy_stub__"] = {
      "https://cdn.example.com/data" => {"status" => 200, "body" => "stubbed"}
    }
    response = js_fetch(window, "https://cdn.example.com/data")

    assert_equal "stubbed", response.__js_call__("text", []).await
  end
end
