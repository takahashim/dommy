# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestNavigation < Minitest::Test
  include RackTestHelper

  def test_visit_resolves_relative_url_against_default_host
    session = Dommy::Rack::Session.new(app_for("GET /posts" => html_response("<h1>Posts</h1>")))
    session.visit("/posts")
    assert_equal "http://example.org/posts", session.current_url
    assert_equal "/posts", session.current_path
    assert_equal "example.org", session.current_host
  end

  def test_follows_302_redirect_as_get
    app = app_for(
      "POST /posts" => [302, {"Location" => "/posts/1"}, []],
      "GET /posts/1" => html_response("<p>Created</p>")
    )
    session = Dommy::Rack::Session.new(app)
    session.post("/posts", params: {"title" => "x"})
    assert_equal "/posts/1", session.current_path
    assert_equal "Created", session.at_css("p").text_content
  end

  def test_307_preserves_method_and_body
    seen = []
    app = app_for(
      "POST /a" => [307, {"Location" => "/b"}, []],
      "POST /b" => ->(req) {
        seen << req.params["k"]
        html_response("<p>ok</p>")
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.post("/a", params: {"k" => "v"})
    assert_equal ["v"], seen
  end

  def test_raises_on_too_many_redirects
    app = app_for("GET /loop" => [302, {"Location" => "/loop"}, []])
    session = Dommy::Rack::Session.new(app, max_redirects: 3)
    assert_raises(Dommy::Rack::TooManyRedirectsError) { session.visit("/loop") }
  end

  def test_cross_origin_navigation_raises
    session = Dommy::Rack::Session.new(app_for({}))
    assert_raises(Dommy::Rack::CrossOriginError) { session.visit("http://evil.com/") }
  end

  def test_back_and_forward
    app = app_for(
      "GET /one" => html_response("<h1>One</h1>"),
      "GET /two" => html_response("<h1>Two</h1>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/one")
    session.visit("/two")
    assert_equal "/two", session.current_path

    session.back
    assert_equal "/one", session.current_path
    assert_equal "One", session.at_css("h1").text_content

    session.forward
    assert_equal "/two", session.current_path
    assert_equal "Two", session.at_css("h1").text_content
  end

  def test_reload_refetches_current_url
    count = 0
    app = app_for("GET /x" => ->(_req) {
      count += 1
      html_response("<p>#{count}</p>")
    })
    session = Dommy::Rack::Session.new(app)
    session.visit("/x")
    session.reload
    assert_equal "2", session.at_css("p").text_content
  end
end
