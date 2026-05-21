# frozen_string_literal: true

require_relative "test_helper"

# Round out Location coverage to match happy-dom's get/set symmetry
# tests for every property + assign accepting URL objects.
class TestLocationFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
  end

  def test_hash_default_empty
    assert_equal("", @loc.__js_get__("hash"))
  end

  def test_hash_set_adds_leading_hash
    @loc.__js_set__("hash", "frag")
    assert_equal("#frag", @loc.__js_get__("hash"))
  end

  def test_hash_set_existing_leading_hash_preserved
    @loc.__js_set__("hash", "#frag")
    assert_equal("#frag", @loc.__js_get__("hash"))
  end

  def test_pathname_default
    assert_equal("/", @loc.__js_get__("pathname"))
  end

  def test_pathname_set
    @loc.__js_set__("pathname", "/users/42")
    assert_equal("/users/42", @loc.__js_get__("pathname"))
  end

  def test_search_default_empty
    assert_equal("", @loc.__js_get__("search"))
  end

  def test_search_set_adds_leading_question
    @loc.__js_set__("search", "q=ruby")
    assert_equal("?q=ruby", @loc.__js_get__("search"))
  end

  def test_search_set_preserves_leading_question
    @loc.__js_set__("search", "?q=ruby")
    assert_equal("?q=ruby", @loc.__js_get__("search"))
  end

  def test_origin_default
    assert_equal("http://localhost", @loc.__js_get__("origin"))
  end

  def test_href_get_full_string
    @loc.__js_set__("pathname", "/foo")
    @loc.__js_set__("search", "?x=1")
    @loc.__js_set__("hash", "section")
    assert_equal("http://localhost/foo?x=1#section", @loc.__js_get__("href"))
  end

  def test_href_set_full_url
    @loc.__js_set__("href", "/about?from=home#top")
    assert_equal("/about", @loc.__js_get__("pathname"))
    assert_equal("?from=home", @loc.__js_get__("search"))
    assert_equal("#top", @loc.__js_get__("hash"))
  end

  def test_assign_accepts_url_object
    url = Dommy::Url.new("/dashboard", "http://localhost")
    @loc.__js_call__("assign", [url.__js_get__("href")])
    assert_equal("/dashboard", @loc.__js_get__("pathname"))
  end

  def test_to_string_returns_href
    assert_equal(@loc.__js_get__("href"), @loc.__js_call__("toString", []))
  end

  def test_protocol_format_includes_colon
    assert_equal("http:", @loc.__js_get__("protocol"))
  end

  def test_host_includes_default_port_stripped
    # Default port 80 is stripped in host string.
    assert_equal("localhost", @loc.__js_get__("host"))
  end

  def test_host_with_non_default_port
    @loc.__js_set__("port", "8080")
    assert_equal("localhost", @loc.__js_get__("hostname"))
    assert_equal("8080", @loc.__js_get__("port"))
  end
end
