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
    mime = Dommy::Internal::MimeType
    assert_equal("shift_jis", mime.charset_of("text/plain; charset=shift_jis"))
    assert_equal("Windows-1252", mime.charset_of('text/html;charset="Windows-1252"'))
    assert_equal("EUC-JP", mime.charset_of("text/html;CHARSET=EUC-JP"))
    assert_nil(mime.charset_of("text/plain"))
  end

  # A `;charset=` inside a quoted parameter value is that value's text, not a
  # parameter of its own. Scanning the whole string for the name read it as one,
  # and took the closing quote with it.
  def test_charset_of_ignores_one_inside_a_quoted_value
    mime = Dommy::Internal::MimeType
    assert_nil(mime.charset_of('multipart/form-data; boundary="a;charset=utf-8"'))
    assert_equal("utf-8", mime.charset_of('multipart/form-data; boundary="a;b"; charset=utf-8'))
    assert_equal('a"b', mime.charset_of('text/html; charset="a\\"b"'))
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

  # The legacy multi-byte encodings decode with the spec's handlers, reading
  # their indexes through Ruby; a few code points where Ruby's tables are not
  # the spec's index (Windows-31J for jis0208, GB18030-2005/2022 over 2000).
  SPEC_DECODES = {
    ["Shift_JIS", "\x80"] => "\u0080",     # the byte itself; Windows-31J has no mapping
    ["Shift_JIS", "\xA1"] => "｡",     # halfwidth ideographic full stop
    ["Shift_JIS", "\xDF"] => "ﾟ",     # halfwidth katakana semi-voiced mark
    ["Shift_JIS", "\x81\x5F"] => "＼", # fullwidth reverse solidus
    ["EUC-JP", "\xA1\xDD"] => "－",    # jis0208's fullwidth hyphen-minus, not U+2212
    ["EUC-KR", "\xA1\xA1"] => "　",
    ["Big5", "\xA1\x40"] => "　",
    ["GBK", "\x80"] => "€",           # euro sign
    ["gb18030", "\xA8\xBC"] => "ḿ",   # GB18030-2005
    ["gb18030", "\xFE\x59"] => "龴",   # GB18030-2022
    ["EUC-JP", "\xFF"] => "�",
  ["Big5", "\xA3\xE1"] => "€",          # from the spec's index; Ruby's HKSCS lacks it
  ["Big5", "\xF9\xFA"] => "╭",
  ["gb18030", "\x81\x30\x81\x30"] => "\u0080", # a four-byte range
  ["gb18030", "\xA3\xA0"] => "\u3000",   # the index's compatibility mapping
  }.freeze

  def test_the_legacy_multi_byte_decoders_follow_the_spec_index
    SPEC_DECODES.each do |(name, bytes), expected|
      assert_equal(expected, Dommy::Encodings.decode(bytes.b, name), "#{name} #{bytes.b.inspect}")
    end
  end

  # A broken sequence gives an ASCII byte back to the stream, so it is not
  # swallowed by the error.
  def test_an_ascii_byte_after_a_broken_lead_is_kept
    assert_equal("�@", Dommy::Encodings.decode("\x81\x40".b, "Big5"))
    assert_equal("A� A", Dommy::Encodings.decode("A\xA1 A".b, "EUC-KR"))
    assert_equal("�$P", Dommy::Encodings.decode("\x1B$P".b, "ISO-2022-JP"))
  end

  # A name the standard does not know is the caller's mistake, and says so
  # instead of surfacing a Hash's KeyError.
  def test_decoder_for_rejects_a_name_outside_the_standard
    error = assert_raises(ArgumentError) { Dommy::Encodings.decoder_for("Nonexistent") }
    assert_match(/not an encoding the standard names/, error.message)
  end

  # HTML's prescan: a <meta charset> or http-equiv Content-Type in the first
  # 1024 bytes, outside comments.
  def test_prescan_finds_a_meta_charset
    assert_equal "Big5", Dommy::Encodings.prescan(%(<!doctype html><meta charset="big5">))
    assert_equal "Shift_JIS", Dommy::Encodings.prescan(%(<meta http-equiv="Content-Type" content="text/html; charset=shift_jis">))
    assert_equal "UTF-8", Dommy::Encodings.prescan(%(<meta charset="utf-16le">))
    assert_nil Dommy::Encodings.prescan(%(<!-- <meta charset="big5"> --><p>x</p>))
  end

  # A document's encoding decides how a link's query is encoded, with the
  # spec's Big5 and ISO-2022-JP encoders.
  def test_a_documents_meta_charset_encodes_link_queries
    query = lambda do |charset, text|
      doc = Dommy.parse(%(<!doctype html><meta charset="#{charset}"><a href="https://e.test/?#{text}">x</a>)).document
      [doc.character_encoding, doc.query_selector("a").__js_get__("search")]
    end
    assert_equal ["Big5", "?%A3%E1"], query.("big5", "€")
    assert_equal ["Big5", "?%26%239731%3B"], query.("big5", "☃")
    assert_equal ["ISO-2022-JP", "?%1B(J\\%1B(B"], query.("iso-2022-jp", "¥")
    assert_equal ["UTF-8", "?%E2%82%AC"], query.("utf-8", "€")
  end

  # Shift_JIS, EUC-JP and EUC-KR encode with the spec's encoders and indexes
  # (Windows-31J's and CP949's, not Ruby's narrower Shift_JIS and EUC-KR):
  # NEC row 13 and CP949's extended hangul have bytes.
  def test_shift_jis_euc_jp_and_euc_kr_encode_with_the_spec_indexes
    query = lambda do |charset, text|
      Dommy.parse(%(<!doctype html><meta charset="#{charset}"><a href="https://e.test/?#{text}">x</a>)).document.query_selector("a").__js_get__("search")
    end
    assert_equal "?%87@%81`", query.("shift_jis", "\u2460\uFF5E")
    assert_equal "?%93%FA%B1\\", query.("shift_jis", "\u65E5\uFF71\u00A5")
    assert_equal "?%C6%FC%8E%B1", query.("euc-jp", "\u65E5\uFF71")
    assert_equal "?%81A%C7%D1", query.("euc-kr", "\uAC02\uD55C")
    assert_equal "?%26%23128512%3B", query.("shift_jis", "\u{1F600}")
  end

  # A document built from bytes takes the encoding they were decoded with:
  # the Content-Type's charset over the page's own <meta>.
  def test_a_document_from_bytes_takes_the_encoding_it_was_decoded_with
    nav = Dommy::Internal::ChildNavigable
    sjis = "<!doctype html><a id=a href=\"/s?q=\u65E5\">x</a>".encode("Windows-31J").b
    win = nav.window_for_response(sjis, "text/html; charset=Shift_JIS", "http://e.test/")
    assert_equal ["Shift_JIS", "http://e.test/s?q=%93%FA"], [win.document.character_encoding, win.document.get_element_by_id("a").href]

    utf8 = "<!doctype html><meta charset=shift_jis><a id=a href=\"/s?q=\u65E5\">x</a>".b
    win = nav.window_for_response(utf8, "text/html; charset=utf-8", "http://e.test/")
    assert_equal ["UTF-8", "http://e.test/s?q=%E6%97%A5"], [win.document.character_encoding, win.document.get_element_by_id("a").href]

    text = nav.window_for_response("caf\xE9".b, "text/plain; charset=iso-8859-1", "http://e.test/t")
    assert_equal "windows-1252", text.document.character_encoding
  end

  # fetch, sendBeacon and cookieStore use the plain URL parser: a query is
  # UTF-8 whatever the document's encoding. A link, XHR and history encode
  # it in the document's.
  def test_fetch_encodes_a_query_in_utf8_on_a_legacy_page
    win = Dommy.parse(%(<!doctype html><meta charset="shift_jis"><p>x</p>))
    win.location.__internal_set_url__("http://e.test/")
    assert_equal "http://e.test/a?q=%93%FA", win.__internal_parse_url__("/a?q=\u65E5")
    assert_equal "http://e.test/a?q=%E6%97%A5", win.__internal_parse_url__("/a?q=\u65E5", utf8: true)

    requested = []
    resources = Object.new
    resources.define_singleton_method(:request) { |method:, url:, **| (requested << url) && nil }
    win.globals["__fetch_handler__"] = Dommy::Resources::FetchHandler.new(resources)
    Dommy::FetchFn.new(win).__js_call__("fetch", ["/a?q=\u65E5", nil])
    assert_equal ["http://e.test/a?q=%E6%97%A5"], requested
  end

  # The legacy decoders copy ASCII runs and look two-byte sequences up
  # instead of handing every byte to the handler; what they produce must be
  # what the handler alone produces, broken sequences, a lead at the end and
  # chunked input included.
  def test_the_shortcuts_decode_as_the_handler_alone_does
    rng = Random.new(20_261_011)
    {
      "Shift_JIS" => Dommy::Encodings::ShiftJisDecoder, "EUC-JP" => Dommy::Encodings::EucJpDecoder,
      "Big5" => Dommy::Encodings::Big5Decoder, "EUC-KR" => Dommy::Encodings::EucKrDecoder,
      "gb18030" => Dommy::Encodings::Gb18030Decoder
    }.each do |name, klass|
      slow = Class.new(klass) { private def idle? = false }
      150.times do
        bytes = Array.new(rng.rand(1..40)) { rng.rand < 0.3 ? rng.rand(0x20..0x7E) : rng.rand(0x80..0xFF) }.pack("C*")
        cut = rng.rand(0..bytes.bytesize)
        fast = klass.new(false)
        expected = slow.new(false)
        got = fast.decode(bytes.byteslice(0, cut), flush: false) + fast.decode(bytes.byteslice(cut..), flush: true)
        want = expected.decode(bytes.byteslice(0, cut), flush: false) + expected.decode(bytes.byteslice(cut..), flush: true)
        assert_equal want, got, "#{name} #{bytes.unpack1("H*")} cut at #{cut}"
      end
    end
  end
end
