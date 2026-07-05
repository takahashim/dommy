# frozen_string_literal: true

require_relative "test_helper"

# Window global helpers (window.btoa / atob, encode/decodeURIComponent).
class TestGlobalFunctions < Minitest::Test
  G = Dommy::Internal::GlobalFunctions

  def test_btoa_encodes_ascii
    assert_equal "aGk=", G.btoa("hi")
    assert_equal "", G.btoa("")
    assert_equal "SGVsbG8sIHdvcmxkIQ==", G.btoa("Hello, world!")
  end

  def test_atob_decodes
    assert_equal "hi", G.atob("aGk=")
    assert_equal "Hello, world!", G.atob("SGVsbG8sIHdvcmxkIQ==")
  end

  def test_atob_tolerates_whitespace_and_missing_padding
    assert_equal "hi", G.atob("aG k=")
    assert_equal "hi", G.atob("aGk") # length not %4==1 -> padded
  end

  def test_btoa_atob_round_trip_over_full_latin1_range
    latin1 = (0..255).map { |c| c.chr(Encoding::UTF_8) }.join
    assert_equal latin1, G.atob(G.btoa(latin1))
  end

  def test_btoa_rejects_characters_outside_latin1
    G.btoa("é") # U+00E9 is within Latin1 -> fine
    assert_raises(Dommy::DOMException::InvalidCharacterError) { G.btoa("Ā") } # U+0100 -> error
  end

  def test_atob_rejects_invalid_base64
    assert_raises(Dommy::DOMException::InvalidCharacterError) { G.atob("@@@@") }
    assert_raises(Dommy::DOMException::InvalidCharacterError) { G.atob("aGk=x") }
  end

  def test_encode_uri_component
    assert_equal "a%20b", G.encode_uri_component("a b")
    assert_equal "%E3%81%82", G.encode_uri_component("あ")
    # The JS unreserved set stays literal (notably * ' ( ) ! ~).
    assert_equal "-_.!~*'()", G.encode_uri_component("-_.!~*'()")
  end

  def test_decode_uri_component_decodes_percent_sequences
    assert_equal "a b", G.decode_uri_component("a%20b")
    assert_equal "あ", G.decode_uri_component("%E3%81%82")
  end

  def test_decode_uri_component_keeps_plus_literal
    # Unlike form-urlencoded decoding, decodeURIComponent must NOT turn "+"
    # into a space (JS: decodeURIComponent("a+b") === "a+b").
    assert_equal "a+b c", G.decode_uri_component("a+b%20c")
    assert_equal "1+2", G.decode_uri_component("1%2B2")
  end

  def test_decode_uri_component_replaces_malformed_utf8
    assert_equal "\u{FFFD}\u{FFFD}", G.decode_uri_component("%FF%FE")
  end

  def test_encode_decode_uri_component_round_trip
    original = "日本語 & symbols +?=/#"
    assert_equal original, G.decode_uri_component(G.encode_uri_component(original))
  end
end
