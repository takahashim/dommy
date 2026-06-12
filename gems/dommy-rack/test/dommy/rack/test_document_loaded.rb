# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestDocumentLoaded < Minitest::Test
  include RackTestHelper

  def app
    app_for(
      "GET /a" => html_response("<p>a</p>"),
      "GET /b" => html_response("<p>b</p>"),
      "POST /posts" => [302, {"Location" => "/a"}, []],
      "GET /api" => [200, {"Content-Type" => "application/json"}, ['{"ok":true}']]
    )
  end

  def test_fires_for_each_html_navigation_with_the_new_window
    session = Dommy::Rack::Session.new(app)
    seen = []
    session.on_document_loaded do |window|
      assert_same session.document, window.document
      seen << window.document.body.text_content.strip
    end

    session.visit("/a")
    session.visit("/b")
    session.back
    assert_equal %w[a b a], seen
  end

  def test_fires_once_for_a_followed_redirect
    session = Dommy::Rack::Session.new(app)
    count = 0
    session.on_document_loaded { count += 1 }

    session.post("/posts")
    assert_equal 1, count
    assert_equal "/a", session.current_path
  end

  def test_does_not_fire_for_fetch_or_non_html_responses
    session = Dommy::Rack::Session.new(app)
    count = 0
    session.on_document_loaded { count += 1 }

    session.fetch("/api")
    session.get("/api")
    assert_equal 0, count
  end
end
