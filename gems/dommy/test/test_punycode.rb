# frozen_string_literal: true

require_relative "test_helper"

# RFC 3492 §7.1 reference vectors plus round-trip checks.
class TestPunycode < Minitest::Test
  P = Dommy::Internal::Punycode

  # Each entry: [unicode_input, bare_punycode]
  RFC_VECTORS = [
    ["ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"],
    ["他们为什么不说中文", "ihqwcrb4cv8a8dqg056pqjye"],
    ["他們爲什麽不說中文", "ihqwctvzc91f659drss3x8bo0yb"],
    ["Pročprostěnemluvíčesky", "Proprostnemluvesky-uyb24dma41a"],
    ["למההםפשוטלאמדבריםעברית", "4dbcagdahymbxekheh6e0a7fei0b"],
    ["почемужеонинеговорятпорусски", "b1abfaaepdrnnbgefbadotcwatmq2g4l"],
    ["PorquénopuedensimplementehablarenEspañol", "PorqunopuedensimplementehablarenEspaol-fmd56a"]
  ].freeze

  def test_encode_matches_rfc_vectors
    RFC_VECTORS.each do |input, expected|
      assert_equal(expected, P.encode(input), "encode(#{input.inspect})")
    end
  end

  def test_decode_matches_rfc_vectors
    RFC_VECTORS.each do |expected, input|
      assert_equal(expected, P.decode(input), "decode(#{input.inspect})")
    end
  end

  def test_roundtrip
    RFC_VECTORS.each do |input, _|
      assert_equal(input, P.decode(P.encode(input)))
    end
  end

  def test_japanese
    # Common dommy fixture: 日本 → wgv71a
    assert_equal("wgv71a", P.encode("日本"))
    assert_equal("日本", P.decode("wgv71a"))
  end

  def test_basic_only_input_produces_trailing_delimiter_form
    # Per RFC 3492 §6.3 the encoder always appends a delimiter when
    # there are basic code points — the decoder needs it to locate
    # the basic / extended boundary.
    assert_equal("hello-", P.encode("hello"))
    assert_equal("hello", P.decode("hello-"))
  end

  def test_mixed_basic_and_extended
    # `büc` — has both ASCII and non-ASCII. Output should contain the
    # ASCII portion, a delimiter, then the encoding of the extended bit.
    encoded = P.encode("büc")
    assert_includes(encoded, "-")
    assert_equal("büc", P.decode(encoded))
  end

  def test_decode_invalid_raises
    assert_raises(Dommy::Internal::Punycode::Error) { P.decode("!!!") }
  end
end
