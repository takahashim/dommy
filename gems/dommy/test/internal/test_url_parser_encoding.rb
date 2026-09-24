# frozen_string_literal: true

require_relative "../test_helper"

# HTML "encoding-parses" URL-valued attributes: it hands the URL parser the
# document's character encoding, which the parser uses to percent-encode the
# query (URL Standard §4.4 query state). Dommy's documents are UTF-8, so this
# only shows at the parser boundary and through Element#resolve_url with a
# document whose encoding says otherwise.
class TestUrlParserEncoding < Minitest::Test
  PARSER = Dommy::Internal::UrlParser

  def serialize(input, encoding)
    PARSER.serialize(PARSER.parse(input, nil, encoding: encoding))
  end

  # The spec's own worked examples (URL §1.3): "≡" is 0x81 0xDF in Shift_JIS,
  # and "‽" is not representable, so it becomes the numeric character reference
  # escape.
  def test_special_url_query_uses_the_encoding
    assert_equal "https://example.com/?%81%DF", serialize("https://example.com/?≡", "Shift_JIS")
    assert_equal "https://example.com/?%81%DF%26%238253%3B", serialize("https://example.com/?≡‽", "Shift_JIS")
  end

  def test_utf8_is_the_default_and_unchanged
    assert_equal "https://example.com/?%E2%89%A1", serialize("https://example.com/?≡", nil)
    assert_equal "https://example.com/?%E2%89%A1", serialize("https://example.com/?≡", "UTF-8")
    assert_equal "https://example.com/?%E2%89%A1", PARSER.serialize(PARSER.parse("https://example.com/?≡"))
  end

  # Query state step 1: a non-special URL, and the ws/wss schemes, force the
  # encoding back to UTF-8.
  def test_non_special_and_ws_ignore_the_encoding
    assert_equal "ws://example.com/?%E2%89%A1", serialize("ws://example.com/?≡", "Shift_JIS")
    assert_equal "foo://example.com/?%E2%89%A1", serialize("foo://example.com/?≡", "Shift_JIS")
  end

  # ASCII (including an already percent-encoded sequence) is unaffected by the
  # encoding choice.
  def test_ascii_query_is_encoding_independent
    assert_equal "https://example.com/?a=1&b=%20", serialize("https://example.com/?a=1&b=%20", "Shift_JIS")
  end

  # The URL API itself is UTF-8 whatever the document says.
  def test_url_api_ignores_the_document_encoding
    assert_equal "https://example.com/?%E2%89%A1", Dommy::URL.new("https://example.com/?≡").href
  end

  # Element#resolve_url hands the document's encoding to the parser, and both
  # URL-valued attribute getters route through it: the reflected ones
  # (img.src) via reflected_url, and the hyperlink ones (a.href) via
  # HyperlinkUtils.
  def test_reflected_url_passes_the_document_encoding
    window = Dommy::Window.new
    document = window.document
    document.body.inner_html = "<img id='i' src='?≡'>"
    def document.character_encoding = "Shift_JIS"

    assert_equal "http://localhost/?%81%DF", document.get_element_by_id("i").src
  end

  def test_hyperlink_href_passes_the_document_encoding
    window = Dommy::Window.new
    document = window.document
    document.body.inner_html = "<a id='a' href='?≡'>x</a>"
    def document.character_encoding = "Shift_JIS"

    assert_equal "http://localhost/?%81%DF", document.get_element_by_id("a").href
  end
end
