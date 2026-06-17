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
end
