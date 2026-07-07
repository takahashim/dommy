# frozen_string_literal: true

require_relative "test_helper"

class TestLocationHistory < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
    @hist = @win.__js_get__("history")
  end

  def test_default_location
    assert_equal("http://localhost", @loc.__js_get__("origin"))
    assert_equal("/", @loc.__js_get__("pathname"))
    assert_equal("", @loc.__js_get__("search"))
    assert_equal("", @loc.__js_get__("hash"))
  end

  def test_href_assignment
    @loc.__js_set__("href", "/foo?q=1#bar")
    assert_equal("/foo", @loc.__js_get__("pathname"))
    assert_equal("?q=1", @loc.__js_get__("search"))
    assert_equal("#bar", @loc.__js_get__("hash"))
  end

  def test_hash_change_fires_event
    fired = []
    # hashchange is a HashChangeEvent exposing full old/new document URLs.
    @win.add_event_listener("hashchange") { |e| fired << [e.__js_get__("oldURL"), e.__js_get__("newURL")] }
    @loc.__js_set__("hash", "section2")
    assert_equal(1, fired.size)
    assert_match(%r{#section2\z}, fired.first[1])
    assert_equal("#section2", @loc.__js_get__("hash"))
  end

  def test_history_push_state
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/page1"])
    assert_equal("/page1", @loc.__js_get__("pathname"))
    assert_equal({"n" => 1}, @hist.__js_get__("state"))
  end

  def test_history_back_fires_popstate
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/page1"])
    @hist.__js_call__("pushState", [{"n" => 2}, "", "/page2"])

    fired = []
    @win.add_event_listener("popstate") { |e| fired << e.__js_get__("state") }
    @hist.__js_call__("back", [])

    assert_equal(1, fired.size)
    assert_equal({"n" => 1}, fired.first)
  end

  def test_url_constructor
    ctor = @win.__js_get__("URL")
    url = ctor.__js_new__(["/about", "http://example.com"])
    assert_equal("http://example.com", url.__js_get__("origin"))
    assert_equal("/about", url.__js_get__("pathname"))
  end
end
