# frozen_string_literal: true

require "test_helper"

# The joint session/window history: same-document (pushState) entries appear
# in the session history and current_url, back/forward traverse them via
# popstate on the live page, and document boundaries fall back to a full
# re-request — matching a browser tab's single history list.
class Dommy::Rack::TestHistorySync < Minitest::Test
  include RackTestHelper

  def build_session
    requests = []
    app = lambda do |env|
      requests << env["PATH_INFO"]
      [200, {"content-type" => "text/html"},
       ["<html><body><h1>#{env["PATH_INFO"]}</h1></body></html>"]]
    end
    [Dommy::Rack::Session.new(app), requests]
  end

  def push_state(session, url)
    session.document.default_view.history.__js_call__("pushState", [nil, nil, url])
  end

  def test_push_state_updates_current_url_and_history
    session, = build_session
    session.visit("/")

    push_state(session, "/posts/1")

    assert_equal "/posts/1", session.current_path
    assert_equal %w[http://example.org/ http://example.org/posts/1], session.history.entries
  end

  def test_back_over_a_push_state_entry_fires_popstate_without_a_request
    session, requests = build_session
    session.visit("/")
    push_state(session, "/posts/1")
    popstates = 0
    session.document.default_view.add_event_listener("popstate", ->(_e) { popstates += 1 })
    requests.clear

    assert_equal "http://example.org/", session.back

    assert_equal 1, popstates
    assert_empty requests
    assert_equal "/", session.current_path

    session.forward

    assert_equal "/posts/1", session.current_path
    assert_empty requests
  end

  def test_back_across_a_document_boundary_re_requests
    session, requests = build_session
    session.visit("/")
    session.visit("/other")
    requests.clear

    session.back

    assert_equal ["/"], requests
    assert_equal "/", session.current_path
  end

  def test_js_initiated_traversal_syncs_the_session_cursor
    session, requests = build_session
    session.visit("/")
    push_state(session, "/posts/1")

    # The page itself goes back (history.back() from JS): the session cursor
    # follows, so a subsequent session.forward returns to the pushed entry.
    session.document.default_view.history.__js_call__("back", [])
    assert_equal "/", session.current_path

    requests.clear
    assert_equal "http://example.org/posts/1", session.forward
    assert_equal "/posts/1", session.current_path
    assert_empty requests
  end

  def test_stale_window_history_operations_do_not_touch_the_session
    session, = build_session
    session.visit("/")
    stale_window = session.document.default_view
    session.visit("/other")

    # A retained handle to the navigated-away page pushes state: the session's
    # URL and joint history must not follow a dead document.
    stale_window.history.__js_call__("pushState", [nil, nil, "/ghost"])

    assert_equal "/other", session.current_path
    assert_equal %w[http://example.org/ http://example.org/other], session.history.entries
  end

  def test_replace_state_updates_current_url_in_place
    session, = build_session
    session.visit("/")

    session.document.default_view.history.__js_call__("replaceState", [nil, nil, "/renamed"])

    assert_equal "/renamed", session.current_path
    assert_equal ["http://example.org/renamed"], session.history.entries
  end
end
