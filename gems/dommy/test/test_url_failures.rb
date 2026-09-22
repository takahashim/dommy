# frozen_string_literal: true

require_relative "test_helper"

# A URL the parser rejects is refused by every API that takes one, each with
# the error its spec names (WPT url/failure.html).
class TestUrlFailures < Minitest::Test
  include DommyTestHelper

  BAD = "http://[::1".freeze # an unclosed IPv6 literal fails with any base

  def setup
    @win = make_window("<p></p>")
  end

  def test_xhr_open_throws_a_syntax_error
    xhr = Dommy::XMLHttpRequest.new(@win)
    error = assert_raises(Dommy::DOMException) { xhr.open("GET", BAD) }
    assert_equal("SyntaxError", error.name)
    xhr.open("GET", "http://example.test/ok")
  end

  def test_send_beacon_throws_a_type_error
    assert_raises(Dommy::Bridge::TypeError) { @win.navigator.send_beacon(BAD) }
    assert_equal(true, @win.navigator.send_beacon("http://example.test/beacon"))
  end

  def test_location_setters_throw_a_syntax_error_and_a_link_does_nothing
    error = assert_raises(Dommy::DOMException) { @win.location.__js_set__("href", BAD) }
    assert_equal("SyntaxError", error.name)
    assert_raises(Dommy::DOMException) { @win.location.__js_call__("assign", [BAD]) }
    assert_raises(Dommy::DOMException) { @win.__js_set__("location", BAD) }
    before = @win.location.href
    @win.location.__internal_navigate_to__(BAD, source: :link)
    assert_equal(before, @win.location.href)
  end

  def test_window_open_throws_a_syntax_error_for_a_bad_url_only
    error = assert_raises(Dommy::DOMException) { @win.__js_call__("open", [BAD]) }
    assert_equal("SyntaxError", error.name)
    assert_nil(@win.__js_call__("open", ["http://example.test/"]))
    assert_nil(@win.__js_call__("open", []))
  end

  def test_parse_url_against_the_document_base
    assert_equal("http://example.test/ok", @win.__internal_parse_url__("http://example.test/ok"))
    assert_nil(@win.__internal_parse_url__(BAD))
  end
end
