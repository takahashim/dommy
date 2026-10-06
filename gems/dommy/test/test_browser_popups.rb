# frozen_string_literal: true

require "test_helper"
require_relative "support/null_runtime"

# window.open of a new top-level browsing context, as Dommy::Browser answers
# the navigation delegate's open_window: a real auxiliary Window with an
# opener, navigated from a task, closable by script.
class TestBrowserPopups < Minitest::Test
  def teardown
    @browser&.dispose
  end

  def page(body) = "<!doctype html><html><head></head><body>#{body}</body></html>"

  def open_browser
    resources = Dommy::Resources.static(
      "/" => {"body" => page("<p>top</p>"), "content_type" => "text/html"},
      "/popup" => {"body" => page("<p id='p'>popup</p>"), "content_type" => "text/html"}
    )
    @browser = Dommy::Browser.visit("http://localhost/", resources: resources, backend: :null)
  end

  def test_blank_target_opens_an_auxiliary_window
    b = open_browser
    win = b.window
    popup = win.window_open("/popup", "_blank", "")

    assert_kind_of Dommy::Window, popup
    assert_same win, popup.__js_get__("opener")
    assert_equal "about:blank", popup.location.href
    assert_equal win.origin, popup.origin, "the initial about:blank has its opener's origin"
    assert_equal [popup], b.popups

    loads = 0
    popup.add_event_listener("load", ->(_e) { loads += 1 })
    b.advance_time(0)

    assert_equal 1, loads
    assert_equal "http://localhost/popup", popup.location.href
    assert_equal "popup", popup.document.get_element_by_id("p").text_content
    assert_same b.storage_provider, popup.storage_provider
    assert_same b.cookie_jar, popup.cookie_jar
  end

  def test_a_popup_closes_itself
    b = open_browser
    popup = b.window.window_open("", "_blank", "")
    popup.close

    assert popup.closed?, "closed as soon as close() begins"
    b.advance_time(0)
    assert_empty b.popups
    assert_nil popup.parent_window
  end

  def test_names_noopener_and_disowning
    b = open_browser
    win = b.window
    named = win.window_open("", "helper", "")
    assert_equal "helper", named.name
    assert_same named, win.window_open("", "helper", "")

    assert_nil win.window_open("/popup", "_blank", "noopener")
    assert_equal 2, b.popups.size
    assert_nil b.popups.last.__js_get__("opener")

    named.__js_set__("opener", nil)
    assert_nil named.__js_get__("opener")
  end

  # HTML "tokenize the features argument" / "parse a boolean feature".
  def test_noopener_and_noreferrer_features
    b = open_browser
    win = b.window
    assert_nil win.window_open("", "_blank", "=NOOPENER")
    assert_nil win.window_open("", "_blank", "a=1, noreferrer")
    assert_nil win.window_open("", "_blank", "noopener=yes")
    refute_nil win.window_open("", "_blank", "noopener=0")
    refute_nil win.window_open("", "_blank", "-noopener")
  end
end
