# frozen_string_literal: true

require_relative "test_helper"

class TestTextCodec < Minitest::Test
  include DommyTestHelper

  # --- TextEncoder ------------------------------------------------

  def test_encoder_encoding
    assert_equal("utf-8", Dommy::TextEncoder.new.encoding)
  end

  def test_encoder_encode_ascii
    assert_equal([72, 105], Dommy::TextEncoder.new.encode("Hi"))
  end

  def test_encoder_encode_japanese
    bytes = Dommy::TextEncoder.new.encode("あ")
    assert_equal([0xe3, 0x81, 0x82], bytes)
  end

  def test_encoder_empty_input
    assert_equal([], Dommy::TextEncoder.new.encode(""))
  end

  def test_encoder_js_bridge
    enc = Dommy::TextEncoder.new
    assert_equal("utf-8", enc.__js_get__("encoding"))
    assert_equal([72, 105], enc.__js_call__("encode", ["Hi"]))
  end

  # --- TextDecoder ------------------------------------------------

  def test_decoder_default_encoding
    assert_equal("utf-8", Dommy::TextDecoder.new.encoding)
  end

  def test_decoder_decode_array_of_bytes
    assert_equal("Hi", Dommy::TextDecoder.new.decode([72, 105]))
  end

  def test_decoder_decode_japanese
    assert_equal("あ", Dommy::TextDecoder.new.decode([0xe3, 0x81, 0x82]))
  end

  def test_decoder_decode_binary_string
    assert_equal("Hi", Dommy::TextDecoder.new.decode("Hi".b))
  end

  def test_decoder_decode_nil_returns_empty
    assert_equal("", Dommy::TextDecoder.new.decode(nil))
  end

  def test_decoder_round_trip_with_encoder
    text = "Hello, 世界 🌍"
    bytes = Dommy::TextEncoder.new.encode(text)
    assert_equal(text, Dommy::TextDecoder.new.decode(bytes))
  end

  def test_decoder_label_normalization
    assert_equal("iso-8859-1", Dommy::TextDecoder.new("ISO-8859-1").encoding)
    assert_equal("iso-8859-1", Dommy::TextDecoder.new("latin1").encoding)
    assert_equal("utf-16le", Dommy::TextDecoder.new("utf-16").encoding)
  end

  def test_window_exposes_text_encoder_constructor
    win = make_window
    ctor = win.__js_get__("TextEncoder")
    enc = ctor.__js_new__([])
    assert_kind_of(Dommy::TextEncoder, enc)
  end

  def test_window_exposes_text_decoder_constructor
    win = make_window
    ctor = win.__js_get__("TextDecoder")
    dec = ctor.__js_new__(["utf-8"])
    assert_kind_of(Dommy::TextDecoder, dec)
    assert_equal("utf-8", dec.encoding)
  end
end
