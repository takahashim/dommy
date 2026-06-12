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

  def test_equal_with_html_entities
    assert Dommy::Rails::UrlNormalizer.equal?(
      "/articles?foo=1&amp;bar=2",
      "/articles?foo=1&bar=2"
    )
  end
end
