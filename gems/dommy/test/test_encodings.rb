# frozen_string_literal: true

require_relative "test_helper"

class TestEncodings < Minitest::Test
  def decoder(label, **options)
    Dommy::TextDecoder.new(label, options)
  end

  # --- labels ------------------------------------------------------------

  def test_labels_map_to_the_spec_names
    assert_equal("windows-1252", decoder("ascii").encoding)
    assert_equal("windows-1252", decoder("iso-8859-1").encoding)
    assert_equal("ibm866", decoder("cp866").encoding)
    assert_equal("iso-8859-8-i", decoder("logical").encoding)
    assert_equal("shift_jis", decoder("sjis").encoding)
    assert_equal("euc-kr", decoder("korean").encoding)
    assert_equal("x-user-defined", decoder("x-user-defined").encoding)
    assert_equal("utf-16be", decoder("UTF-16BE").encoding)
  end

  def test_ascii_whitespace_around_a_label_is_ignored_but_other_whitespace_is_not
    assert_equal("utf-8", decoder(" \t\n\f\rutf-8\r\n ").encoding)
    assert_raises(Dommy::Bridge::RangeError) { decoder("\u00a0utf-8") }
    assert_raises(Dommy::Bridge::RangeError) { decoder("utf-8\u0000") }
  end

  def test_an_unknown_label_is_a_range_error
    error = assert_raises(Dommy::Bridge::RangeError) { decoder("nonsense") }
    assert_includes(error.message, "nonsense")
    assert_raises(Dommy::Bridge::RangeError) { decoder("") }
    assert_raises(Dommy::Bridge::RangeError) { decoder(nil) } # "null"
  end

  def test_the_replacement_encoding_is_rejected
    %w[replacement hz-gb-2312 iso-2022-kr csiso2022kr].each do |label|
      assert_raises(Dommy::Bridge::RangeError, label) { decoder(label) }
    end
  end

  def test_undefined_label_is_utf8
    assert_equal("utf-8", Dommy::TextDecoder.new(Dommy::Bridge::UNDEFINED).encoding)
  end

  def test_get
    assert_equal("windows-1252", Dommy::Encodings.get("Latin1"))
    assert_nil(Dommy::Encodings.get("utf-9"))
  end

  # --- single-byte encodings -----------------------------------------------

  def test_single_byte_decoding_follows_the_spec_index
    assert_equal("\u20ac\u0081", decoder("windows-1252").decode([0x80, 0x81])) # not Latin-1's U+0080
    assert_equal("\u0410", decoder("ibm866").decode([0x80]))
    assert_equal("\u00c4", decoder("macintosh").decode([0x80]))
    assert_equal("\u0e01", decoder("windows-874").decode([0xa1]))
    assert_equal("\u05d0", decoder("iso-8859-8-i").decode([0xe0]))
    assert_equal("abc", decoder("koi8-r").decode("abc".b))
  end

  def test_an_unmapped_byte_is_a_replacement_character_or_a_type_error
    assert_equal("\ufffd", decoder("iso-8859-3").decode([0xa5]))
    assert_equal("\ufffdA", decoder("iso-8859-8").decode([0xff, 0x41]))
    assert_raises(Dommy::Bridge::TypeError) { decoder("iso-8859-3", fatal: true).decode([0xa5]) }
    assert_equal("\u0143", decoder("iso-8859-2", fatal: true).decode([0xd1]))
  end

  def test_x_user_defined
    assert_equal("a\uf780\uf7ff", decoder("x-user-defined").decode([0x61, 0x80, 0xff]))
  end

  def test_no_bom_stripping_for_single_byte_encodings
    assert_equal("\u00ef\u00bb\u00bfx", decoder("windows-1252").decode([0xef, 0xbb, 0xbf, 0x78]))
  end

  # --- UTF-16 ------------------------------------------------------------

  def test_utf16_little_and_big_endian
    assert_equal("A\u3042", decoder("utf-16le").decode([0x41, 0x00, 0x42, 0x30]))
    assert_equal("A\u3042", decoder("utf-16be").decode([0x00, 0x41, 0x30, 0x42]))
    assert_equal("\u{1f600}", decoder("utf-16").decode([0x3d, 0xd8, 0x00, 0xde]))
  end

  def test_utf16_bom_is_stripped_unless_ignored
    assert_equal("A", decoder("utf-16le").decode([0xff, 0xfe, 0x41, 0x00]))
    assert_equal("\ufeffA", decoder("utf-16le", ignoreBOM: true).decode([0xff, 0xfe, 0x41, 0x00]))
    assert_equal("\ufffeA", decoder("utf-16le").decode([0xfe, 0xff, 0x41, 0x00])) # the other endianness is data
    assert_equal("A", decoder("utf-16be").decode([0xfe, 0xff, 0x00, 0x41]))
  end

  def test_utf16_streaming_keeps_a_split_code_unit_and_a_lead_surrogate
    d = decoder("utf-16le")
    assert_equal("", d.decode([0x41], stream: true))
    assert_equal("A", d.decode([0x00, 0x3d], stream: true))
    assert_equal("", d.decode([0xd8], stream: true))
    assert_equal("\u{1f600}", d.decode([0x00, 0xde]))
  end

  def test_utf16_lone_surrogates
    assert_equal("\ufffdA", decoder("utf-16le").decode([0x00, 0xdc, 0x41, 0x00])) # a lone trail
    assert_equal("\ufffdA", decoder("utf-16le").decode([0x00, 0xd8, 0x41, 0x00])) # a lead without a trail
    assert_equal("\ufffd\u{1f600}", decoder("utf-16le").decode([0x00, 0xd8, 0x3d, 0xd8, 0x00, 0xde]))
    assert_equal("A\ufffd", decoder("utf-16le").decode([0x41, 0x00, 0x00])) # an odd byte at the end
    assert_raises(Dommy::Bridge::TypeError) { decoder("utf-16le", fatal: true).decode([0x00, 0xdc]) }
  end

  # --- legacy multi-byte encodings ----------------------------------------

  def test_multibyte_encodings_through_ruby_converters
    assert_equal("\u3042", decoder("shift_jis").decode([0x82, 0xa0]))
    assert_equal("\u3042", decoder("euc-jp").decode([0xa4, 0xa2]))
    assert_equal("\u4e2d", decoder("gbk").decode([0xd6, 0xd0]))
    assert_equal("\u4e2d", decoder("gb18030").decode([0xd6, 0xd0]))
    assert_equal("\u4e2d", decoder("big5").decode([0xa4, 0xa4]))
    assert_equal("\ud55c", decoder("euc-kr").decode([0xc7, 0xd1]))
    assert_equal("\u3042", decoder("iso-2022-jp").decode("\e$B$\"\e(B".b))
  end

  def test_multibyte_streaming_holds_a_split_character
    d = decoder("shift_jis")
    assert_equal("", d.decode([0x82], stream: true))
    assert_equal("\u3042", d.decode([0xa0]))
    assert_equal("\ufffd", decoder("shift_jis").decode([0x82]))
    assert_raises(Dommy::Bridge::TypeError) { decoder("shift_jis", fatal: true).decode([0x82]) }
  end

  def test_multibyte_invalid_bytes
    assert_equal("\ufffdA", decoder("shift_jis").decode([0xff, 0x41]))
    assert_raises(Dommy::Bridge::TypeError) { decoder("shift_jis", fatal: true).decode([0xff, 0x41]) }
  end

  # --- the decoder state resets after a non-streaming call -----------------

  def test_a_decoder_starts_over_after_a_flush
    d = decoder("utf-8")
    assert_equal("\ufffd", d.decode([0xe3]))
    assert_equal("\u3042", d.decode([0xe3, 0x81, 0x82]))
    assert_equal("", d.decode)
  end

  # --- decode, as XMLHttpRequest reads a response --------------------------

  def test_decode_sniffs_a_byte_order_mark_over_the_named_encoding
    assert_equal("\u3042", Dommy::Encodings.decode("\xEF\xBB\xBF\xE3\x81\x82".b, "Shift_JIS"))
    assert_equal("A", Dommy::Encodings.decode("\xFF\xFE\x41\x00".b, "windows-1252"))
    assert_equal("A", Dommy::Encodings.decode("\xFE\xFF\x00\x41".b))
    assert_equal("\u3042", Dommy::Encodings.decode("\x82\xA0".b, "Shift_JIS"))
    assert_equal("\ufffd\ufffd", Dommy::Encodings.decode("\x82\xA0".b))
  end

  def test_charset_of_a_mime_type
    assert_equal("shift_jis", Dommy::Encodings.charset_of("text/plain; charset=shift_jis"))
    assert_equal("Windows-1252", Dommy::Encodings.charset_of('text/html;charset="Windows-1252"'))
    assert_nil(Dommy::Encodings.charset_of("text/plain"))
  end

  def test_xhr_response_text_uses_the_response_charset_then_override_mime_type
    win = Dommy.parse("<p></p>")
    win.__js_set__("__fetchy_stub__", {
      "/sjis" => {"body" => "\x82\xA0".b, "contentType" => "text/plain; charset=shift_jis"},
      "/bom" => {"body" => "\xEF\xBB\xBF\xE3\x81\x82".b, "contentType" => "text/plain; charset=shift_jis"},
      "/plain" => {"body" => "\xE3\x81\x82".b, "contentType" => "text/plain"}
    })
    xhr = Dommy::XMLHttpRequest.new(win)
    xhr.open("GET", "/sjis", false)
    xhr.send
    assert_equal("\u3042", xhr.response_text)

    xhr = Dommy::XMLHttpRequest.new(win)
    xhr.open("GET", "/sjis", false)
    xhr.override_mime_type("text/plain; charset=utf-8")
    xhr.send
    assert_equal("\ufffd\ufffd", xhr.response_text)

    xhr = Dommy::XMLHttpRequest.new(win)
    xhr.open("GET", "/bom", false)
    xhr.send
    assert_equal("\u3042", xhr.response_text) # the byte-order mark wins

    xhr = Dommy::XMLHttpRequest.new(win)
    xhr.open("GET", "/plain", false)
    xhr.send
    assert_equal("\u3042", xhr.response_text)
    assert_equal("\u3042", xhr.response)
  end

  # --- the JS side ---------------------------------------------------------

  def test_js_constructor_rejects_an_unknown_label_with_a_range_error
    win = Dommy.parse("<p></p>")
    ctor = win.__js_get__("TextDecoder")
    assert_raises(Dommy::Bridge::RangeError) { ctor.__js_new__(["utf-9"]) }
    assert_equal("windows-1251", ctor.__js_new__(["cp1251"]).encoding)
  end

  def test_text_encoder_ignores_its_label
    assert_equal("utf-8", Dommy::TextEncoder.new.encoding)
  end
end
