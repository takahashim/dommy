# frozen_string_literal: true

require "test_helper"
require "support/null_runtime"

# An iframe always has a child navigable whose first document is the initial
# about:blank. With `load_frames: true` a JS session navigates it to its `src`
# through the app (the PageNavigationDelegate's `load_frame`); by default the
# frame stays at about:blank and #within_frame fetches it on demand.
class Dommy::Rack::TestFrameLoading < Minitest::Test
  include RackTestHelper

  def setup
    @previous_factory = DommyRackTestSupport::NullRuntimeBackend.install
  end

  def teardown
    DommyRackTestSupport::NullRuntimeBackend.restore(@previous_factory)
  end

  def app
    app_for(
      "GET /" => html_response("<!doctype html><html><body><iframe id='f' src='/frame'></iframe></body></html>"),
      "GET /frame" => html_response("<!doctype html><html><body><p id='inner'>framed</p></body></html>")
    )
  end

  def test_frames_load_from_the_app_when_enabled
    session = Dommy::Rack::Session.new(app, javascript: true, load_frames: true)
    session.visit("/")
    # The frame's navigation runs from a task, which the visit settles.
    frame = session.document.query_selector("#f")
    assert_equal "framed", frame.content_document.query_selector("#inner").text_content
    assert_equal "http://example.org/frame", frame.content_document.url
  end

  def test_frames_stay_at_about_blank_by_default
    requests = []
    session = Dommy::Rack::Session.new(->(env) { requests << env["PATH_INFO"]; app.call(env) }, javascript: true)
    session.visit("/")

    frame = session.document.query_selector("#f")
    assert_equal "about:blank", frame.content_document.url
    assert_equal ["/"], requests
  end
end
