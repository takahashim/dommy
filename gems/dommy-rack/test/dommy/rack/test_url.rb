# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestUrl < Minitest::Test
  Url = Dommy::Rack::Url

  def test_resolve_percent_encodes_non_ascii_path_as_utf8
    assert_equal "https://note.com/hashtag/%E5%BF%9C%E6%8F%B4",
                 Url.resolve("https://note.com", "/hashtag/応援")
  end

  def test_resolve_percent_encodes_query_and_fragment_non_ascii
    assert_equal "https://note.com/s?q=%E7%8C%AB#%E7%8A%AC",
                 Url.resolve("https://note.com", "/s?q=猫#犬")
  end

  def test_resolve_against_base
    assert_equal "https://note.com/hashtag/x", Url.resolve("https://note.com/old", "/hashtag/x")
  end

  def test_resolve_absolute_url_ignores_base
    assert_equal "https://other.test/y", Url.resolve("https://note.com", "https://other.test/y")
  end

  def test_resolve_returns_nil_on_failure
    assert_nil Url.resolve("not a url", "/x")
  end

  def test_same_origin_true_for_matching_scheme_host_port
    assert Url.same_origin?("http://example.org/a", "http://example.org/b?x=1")
  end

  def test_same_origin_false_for_different_scheme
    refute Url.same_origin?("http://example.org/a", "https://example.org/a")
  end

  def test_same_origin_false_for_different_port
    refute Url.same_origin?("http://example.org:8080/a", "http://example.org/a")
  end

  def test_same_origin_false_when_unparseable
    refute Url.same_origin?("not a url", "http://example.org/a")
  end

  def test_server_port_defaults_when_omitted
    assert_equal "80", Url.server_port(Dommy::URL.new("http://example.org/"))
    assert_equal "443", Url.server_port(Dommy::URL.new("https://example.org/"))
    assert_equal "80", Url.server_port(Dommy::URL.new("ws://example.org/"))
    assert_equal "443", Url.server_port(Dommy::URL.new("wss://example.org/"))
  end

  def test_server_port_explicit
    assert_equal "8080", Url.server_port(Dommy::URL.new("http://example.org:8080/"))
  end

  def test_origin_is_tuple_origin_for_websocket_scheme
    assert_equal "ws://example.org", Url.origin(Dommy::URL.new("ws://example.org/socket"))
  end
end
