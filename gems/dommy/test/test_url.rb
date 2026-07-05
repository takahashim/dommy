# frozen_string_literal: true

require_relative "test_helper"

class TestURLBasics < Minitest::Test
  def test_parse_basic
    u = Dommy::URL.new("https://example.test/a/b?k=v#h")
    assert_equal("https://example.test/a/b?k=v#h", u.href)
    assert_equal("https:", u.protocol)
    assert_equal("example.test", u.host)
    assert_equal("example.test", u.hostname)
    assert_equal("/a/b", u.pathname)
    assert_equal("?k=v", u.search)
    assert_equal("#h", u.hash)
  end

  def test_origin
    u = Dommy::URL.new("https://example.test:8443/a")
    assert_equal("https://example.test:8443", u.origin)
  end

  def test_origin_default_port_omitted
    u = Dommy::URL.new("https://example.test:443/a")
    assert_equal("https://example.test", u.origin)
  end

  def test_invalid_url_raises_type_error
    # WHATWG URL Standard: the constructor throws TypeError (not a DOMException)
    # on a parse failure. Dommy signals it via Bridge::TypeError so a JS host
    # can rethrow a real `TypeError`.
    assert_raises(Dommy::Bridge::TypeError) { Dommy::URL.new("not a url") }
  end

  def test_relative_with_base
    u = Dommy::URL.new("/path", "https://example.test/old")
    assert_equal("https://example.test/path", u.href)
  end

  def test_relative_with_base_url_instance
    base = Dommy::URL.new("https://example.test/")
    u = Dommy::URL.new("a/b", base)
    assert_equal("https://example.test/a/b", u.href)
  end

  def test_default_port_makes_host_no_port
    u = Dommy::URL.new("https://example.test:443/a")
    assert_equal("example.test", u.host)
    assert_equal("", u.port)
  end

  def test_non_default_port_in_host
    u = Dommy::URL.new("http://example.test:8080/a")
    assert_equal("example.test:8080", u.host)
    assert_equal("8080", u.port)
  end
end

# WHATWG-ish behavior for opaque-body schemes (no authority section)
# and verbatim search-string preservation.
class TestURLOpaqueAndRawSearch < Minitest::Test
  def test_javascript_scheme_preserves_body
    u = Dommy::URL.new("javascript:alert(1)")
    assert_equal("javascript:alert(1)", u.href)
    assert_equal("javascript:", u.protocol)
    assert_equal("alert(1)", u.pathname)
  end

  def test_mailto_scheme_preserves_body
    u = Dommy::URL.new("mailto:foo@bar.com")
    assert_equal("mailto:foo@bar.com", u.href)
    assert_equal("foo@bar.com", u.pathname)
  end

  def test_data_scheme_preserves_body
    u = Dommy::URL.new("data:text/plain,hello")
    assert_equal("data:text/plain,hello", u.href)
    assert_equal("text/plain,hello", u.pathname)
  end

  def test_tel_scheme_preserves_body
    u = Dommy::URL.new("tel:+1-555-1234")
    assert_equal("tel:+1-555-1234", u.href)
  end

  def test_search_preserves_percent_encoded_space
    u = Dommy::URL.new("http://h.test/?k=%20v")
    assert_equal("?k=%20v", u.search)
  end

  def test_search_preserves_multiple_question_marks
    u = Dommy::URL.new("http://h.test/p?a?b")
    assert_equal("?a?b", u.search)
  end

  def test_search_params_still_form_encoded
    # `searchParams.toString()` follows application/x-www-form-urlencoded
    # — space stays as `+`. Distinct from `url.search`, which is raw.
    u = Dommy::URL.new("http://h.test/?k=%20v")
    assert_equal("k=+v", u.search_params.to_s)
  end
end

# IDN hosts are Punycode-encoded transparently, matching WHATWG behavior.
# Limitations (no NFC / Bidi) are intentional — see README.
class TestURLIDN < Minitest::Test
  def test_idn_host_encoded_to_punycode
    u = Dommy::URL.new("http://日本.test/")
    assert_equal("xn--wgv71a.test", u.host)
    assert_equal("xn--wgv71a.test", u.hostname)
    assert_equal("http://xn--wgv71a.test/", u.href)
  end

  def test_ascii_host_lowercased
    u = Dommy::URL.new("http://EXAMPLE.com/path")
    assert_equal("example.com", u.host)
  end

  def test_pre_encoded_xn_host_passthrough
    u = Dommy::URL.new("http://xn--wgv71a.test/")
    assert_equal("xn--wgv71a.test", u.host)
    assert_equal("http://xn--wgv71a.test/", u.href)
  end

  def test_idn_host_with_port
    u = Dommy::URL.new("http://日本.test:8080/p")
    assert_equal("xn--wgv71a.test:8080", u.host)
    assert_equal("8080", u.port)
  end

  def test_idn_host_with_userinfo
    u = Dommy::URL.new("http://u:p@日本.test/")
    assert_equal("http://u:p@xn--wgv71a.test/", u.href)
  end

  def test_idn_host_via_base
    u = Dommy::URL.new("/p", "http://日本.test")
    assert_equal("http://xn--wgv71a.test/p", u.href)
  end

  def test_invalid_url_still_raises
    # WHATWG: the URL constructor throws TypeError on a parse failure.
    assert_raises(Dommy::Bridge::TypeError) { Dommy::URL.new("not a url") }
  end
end

# WHATWG URL preprocessing — accept inputs Ruby's URI would reject:
# whitespace, tabs/newlines, backslashes (for special schemes),
# non-ASCII / control / `<>{}|` in path, etc.
class TestURLWhatwgPreprocessing < Minitest::Test
  def test_strips_leading_trailing_whitespace
    assert_equal("http://h.test/", Dommy::URL.new("  http://h.test/  ").href)
  end

  def test_strips_embedded_tab_and_newline
    assert_equal("http://h.test/p", Dommy::URL.new("http://h.test\t/p").href)
    assert_equal("http://h.test/p", Dommy::URL.new("http://h.test\n/p").href)
  end

  def test_percent_encodes_space_in_path
    assert_equal("/a%20b", Dommy::URL.new("http://h.test/a b").pathname)
  end

  def test_percent_encodes_angle_brackets_and_braces
    assert_equal("/%3Cx%3E%7By%7D", Dommy::URL.new("http://h.test/<x>{y}").pathname)
  end

  def test_does_not_double_encode_existing_percent_sequences
    assert_equal("/a%20b", Dommy::URL.new("http://h.test/a%20b").pathname)
  end

  def test_backslash_to_slash_in_special_scheme
    assert_equal("http://h.test/path", Dommy::URL.new("http://h.test\\path").href)
  end

  def test_empty_path_normalized_to_slash_for_special_scheme
    assert_equal("/", Dommy::URL.new("http://h.test").pathname)
    assert_equal("http://h.test/", Dommy::URL.new("http://h.test").href)
  end

  def test_opaque_scheme_path_not_normalized
    # mailto/javascript/etc. preserve their body verbatim.
    assert_equal("foo@bar.com", Dommy::URL.new("mailto:foo@bar.com").pathname)
    assert_equal("alert(1)", Dommy::URL.new("javascript:alert(1)").pathname)
  end
end

class TestURLPathNormalization < Minitest::Test
  def test_dotdot_segment_collapsed
    assert_equal("/a/c", Dommy::URL.new("http://h.test/a/b/../c").pathname)
  end

  def test_dot_segment_skipped
    assert_equal("/a/b", Dommy::URL.new("http://h.test/a/./b").pathname)
  end

  def test_multiple_dotdot
    # `/a/b/c/../../x` → two pops from `c` reach `a`, then `x`.
    assert_equal("/a/x", Dommy::URL.new("http://h.test/a/b/c/../../x").pathname)
  end

  def test_trailing_slash_preserved
    assert_equal("/a/b/", Dommy::URL.new("http://h.test/a/b/").pathname)
  end
end

class TestURLIPv4Normalization < Minitest::Test
  def test_hex_form
    assert_equal("127.0.0.1", Dommy::URL.new("http://0x7f000001/").host)
  end

  def test_octal_form
    assert_equal("127.0.0.1", Dommy::URL.new("http://0177.0.0.1/").host)
  end

  def test_short_two_segment_form
    # `0x7f.1` → 127.0.0.1 (last segment is 24-bit, but `1` fits in 8)
    assert_equal("127.0.0.1", Dommy::URL.new("http://0x7f.1/").host)
  end

  def test_single_decimal_number
    # 2130706433 == 0x7f000001
    assert_equal("127.0.0.1", Dommy::URL.new("http://2130706433/").host)
  end

  def test_standard_dotted_quad_untouched
    assert_equal("192.168.1.1", Dommy::URL.new("http://192.168.1.1/").host)
  end

  def test_non_ipv4_passthrough
    # Anything that isn't an IPv4 number form is left alone.
    assert_equal("h.test", Dommy::URL.new("http://h.test/").host)
  end
end

class TestURLOriginAndPorts < Minitest::Test
  def test_ws_default_port_80_stripped
    assert_equal("ws://h.test/", Dommy::URL.new("ws://h.test:80/").href)
    assert_equal("", Dommy::URL.new("ws://h.test:80/").port)
  end

  def test_wss_default_port_443_stripped
    assert_equal("wss://h.test/", Dommy::URL.new("wss://h.test:443/").href)
    assert_equal("", Dommy::URL.new("wss://h.test:443/").port)
  end

  def test_ws_non_default_port_kept
    assert_equal("ws://h.test:8080/", Dommy::URL.new("ws://h.test:8080/").href)
    assert_equal("8080", Dommy::URL.new("ws://h.test:8080/").port)
  end

  def test_http_default_port_still_stripped
    assert_equal("http://h.test/", Dommy::URL.new("http://h.test:80/").href)
  end

  def test_file_origin_is_null
    assert_equal("null", Dommy::URL.new("file:///p/a").origin)
    assert_equal("null", Dommy::URL.new("file://host/p").origin)
  end

  def test_data_origin_is_null
    assert_equal("null", Dommy::URL.new("data:text/plain,hi").origin)
  end

  def test_javascript_origin_is_null
    assert_equal("null", Dommy::URL.new("javascript:alert(1)").origin)
  end

  def test_blob_origin_resolves_inner_url
    assert_equal("http://x.test", Dommy::URL.new("blob:http://x.test/abc").origin)
    assert_equal(
      "https://x.test:8443",
      Dommy::URL.new("blob:https://x.test:8443/abc").origin
    )
  end

  def test_blob_with_invalid_inner_url_returns_null
    assert_equal("null", Dommy::URL.new("blob:not-a-url").origin)
  end

  def test_http_origin_tuple
    assert_equal("http://h.test", Dommy::URL.new("http://h.test/p").origin)
  end

  def test_ws_origin_tuple
    assert_equal("ws://h.test", Dommy::URL.new("ws://h.test/").origin)
  end

  def test_ftp_origin_tuple
    assert_equal("ftp://files.test", Dommy::URL.new("ftp://files.test/p").origin)
  end
end

class TestURLHostnameSetter < Minitest::Test
  def test_setter_idn_encodes_non_ascii
    u = Dommy::URL.new("http://x.test/")
    u.hostname = "日本.test"
    assert_equal("xn--wgv71a.test", u.hostname)
    assert_equal("http://xn--wgv71a.test/", u.href)
  end

  def test_setter_lowercases_ascii
    u = Dommy::URL.new("http://x.test/")
    u.hostname = "EXAMPLE.com"
    assert_equal("example.com", u.hostname)
  end
end

class TestURLMutation < Minitest::Test
  def test_set_pathname
    u = Dommy::URL.new("https://example.test/")
    u.pathname = "/new"
    assert_equal("/new", u.pathname)
    assert_includes(u.href, "/new")
  end

  def test_set_search_string
    u = Dommy::URL.new("https://example.test/")
    u.search = "?a=1"
    assert_equal("?a=1", u.search)
    assert_equal("1", u.search_params.get("a"))
  end

  def test_set_hash
    u = Dommy::URL.new("https://example.test/")
    u.hash = "x"
    assert_equal("#x", u.hash)
  end

  def test_search_params_set_reflects_in_search
    u = Dommy::URL.new("https://example.test/?k=v")
    u.search_params.set("k", "new")
    assert_equal("new", u.search_params.get("k"))
    assert_includes(u.search, "k=new")
  end

  def test_set_href_reparses
    u = Dommy::URL.new("https://example.test/")
    u.href = "http://other.test/x"
    assert_equal("http://other.test/x", u.href)
    assert_equal("other.test", u.hostname)
  end

  def test_to_s_is_href
    u = Dommy::URL.new("https://example.test/a")
    assert_equal(u.href, u.to_s)
  end
end

class TestURLSearchParams < Minitest::Test
  def test_parse_from_string
    p = Dommy::URLSearchParams.new("a=1&b=2")
    assert_equal("1", p.get("a"))
    assert_equal("2", p.get("b"))
  end

  def test_parse_from_string_with_leading_question
    p = Dommy::URLSearchParams.new("?a=1")
    assert_equal("1", p.get("a"))
  end

  def test_parse_empty_string
    p = Dommy::URLSearchParams.new("")
    assert_equal(0, p.size)
  end

  def test_parse_array_of_pairs
    p = Dommy::URLSearchParams.new([["k", "v"], ["k", "w"]])
    assert_equal(["v", "w"], p.get_all("k"))
  end

  def test_parse_decodes_plus_as_space_and_percent_2b_as_plus
    p = Dommy::URLSearchParams.new("a=x+y&b=1%2B2")
    assert_equal("x y", p.get("a"))
    assert_equal("1+2", p.get("b"))
  end

  def test_parse_decodes_utf8_and_replaces_malformed_sequences
    p = Dommy::URLSearchParams.new("jp=%E3%81%82&bad=%FF%FE")
    assert_equal("あ", p.get("jp"))
    assert_equal("\u{FFFD}\u{FFFD}", p.get("bad"))
  end

  def test_parse_hash
    p = Dommy::URLSearchParams.new({"a" => "1"})
    assert_equal("1", p.get("a"))
  end

  def test_append_preserves_order
    p = Dommy::URLSearchParams.new("a=1")
    p.append("a", "2")
    assert_equal(["1", "2"], p.get_all("a"))
  end

  def test_set_replaces_first_and_removes_rest
    p = Dommy::URLSearchParams.new("a=1&a=2&b=3")
    p.set("a", "z")
    assert_equal(["z"], p.get_all("a"))
    assert_equal("3", p.get("b"))
  end

  def test_set_appends_when_missing
    p = Dommy::URLSearchParams.new("a=1")
    p.set("b", "2")
    assert_equal("2", p.get("b"))
  end

  def test_has
    p = Dommy::URLSearchParams.new("a=1")
    assert(p.has("a"))
    refute(p.has("b"))
  end

  def test_delete_removes_all_with_name
    p = Dommy::URLSearchParams.new("a=1&a=2&b=3")
    p.delete("a")
    refute(p.has("a"))
    assert_equal("3", p.get("b"))
  end

  def test_delete_with_value_removes_only_matching
    p = Dommy::URLSearchParams.new("a=1&a=2&a=1")
    p.delete("a", "1")
    assert_equal(["2"], p.get_all("a"))
  end

  def test_to_string
    p = Dommy::URLSearchParams.new
    p.append("name", "ümlaut")
    p.append("k", "v")
    s = p.to_s
    assert_includes(s, "name=%C3%BCmlaut")
    assert_includes(s, "k=v")
  end

  def test_sort
    p = Dommy::URLSearchParams.new("c=3&a=1&b=2")
    p.sort
    assert_equal(["a", "b", "c"], p.keys)
  end

  def test_for_each
    seen = []
    Dommy::URLSearchParams.new("a=1&b=2").for_each { |v, k, _| seen << [k, v] }
    assert_equal([["a", "1"], ["b", "2"]], seen)
  end

  def test_entries
    e = Dommy::URLSearchParams.new("a=1").entries
    assert_equal([["a", "1"]], e)
  end

  def test_size_is_pair_count
    assert_equal(2, Dommy::URLSearchParams.new("a=1&b=2").size)
    assert_equal(3, Dommy::URLSearchParams.new("a=1&a=2&b=3").size)
  end
end
