# frozen_string_literal: true

require "test_helper"

class TestUrlNormalizer < Minitest::Test
  def test_equal_with_different_hosts
    assert Dommy::Rails::UrlNormalizer.equal?(
      "http://www.example.com/articles/1",
      "http://localhost:3000/articles/1"
    )
  end

  def test_equal_with_query_param_order
    assert Dommy::Rails::UrlNormalizer.equal?(
      "/articles?foo=1&bar=2",
      "/articles?bar=2&foo=1"
    )
  end

  # A raw space or non-ASCII is the percent-encoded URL a helper writes,
  # and a trailing slash goes.
  def test_equal_with_raw_and_encoded_paths
    assert Dommy::Rails::UrlNormalizer.equal?("/tags/a b/", "/tags/a%20b")
    assert Dommy::Rails::UrlNormalizer.equal?("/tags/\u65E5", "/tags/%E6%97%A5")
  end

  # Equal names keep their order: the values of a repeated key are a list.
  def test_query_sort_is_stable
    refute Dommy::Rails::UrlNormalizer.equal?("/a?k=1&k=2", "/a?k=2&k=1")
    assert_equal "/a?b=1&k=1&k=2", Dommy::Rails::UrlNormalizer.normalize("/a?k=1&b=1&k=2")
  end

  def test_equal_with_html_entities
    assert Dommy::Rails::UrlNormalizer.equal?(
      "/articles?foo=1&amp;bar=2",
      "/articles?foo=1&bar=2"
    )
  end
end
