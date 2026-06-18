# frozen_string_literal: true

require_relative "test_helper"

# `data:` URI decoding (RFC 2397), shared by fetch + XHR so an inline
# `data:image/svg+xml;base64,…` resolves like a browser instead of 404ing.
class TestDataUri < Minitest::Test
  include DommyTestHelper

  def test_parse_base64
    decoded = Dommy::DataUri.parse("data:image/svg+xml;base64,#{["<svg/>"].pack("m0")}")
    assert_equal "<svg/>", decoded[:body]
    assert_equal "image/svg+xml", decoded[:content_type]
  end

  def test_parse_percent_encoded
    decoded = Dommy::DataUri.parse("data:text/plain,a%20b%2Cc")
    assert_equal "a b,c", decoded[:body]
    assert_equal "text/plain", decoded[:content_type]
  end

  def test_parse_defaults_media_type_when_omitted
    decoded = Dommy::DataUri.parse("data:,hi")
    assert_equal "hi", decoded[:body]
    assert_equal "text/plain;charset=US-ASCII", decoded[:content_type]
  end

  def test_body_is_utf8
    decoded = Dommy::DataUri.parse("data:text/plain;base64,#{["café"].pack("m0")}")
    assert_equal Encoding::UTF_8, decoded[:body].encoding
    assert_equal "café", decoded[:body]
  end

  def test_non_data_url_returns_nil
    assert_nil Dommy::DataUri.parse("https://example.com/x.svg")
    assert_nil Dommy::DataUri.parse("/relative")
    assert_nil Dommy::DataUri.parse("data:malformed-no-comma")
  end

  # fetch() to a data: URL resolves to a 200 with the decoded payload.
  def test_fetch_resolves_data_uri
    win = make_window
    response = Dommy::FetchFn.new(win).__js_call__("fetch", ["data:text/plain,hello", nil]).await
    assert_equal 200, response.__js_get__("status")
    assert_equal "hello", response.__js_call__("text", []).await
  end
end
