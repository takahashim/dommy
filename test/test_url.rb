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

  def test_invalid_url_raises_syntax_error
    assert_raises(Dommy::DOMException::SyntaxError) { Dommy::URL.new("not a url") }
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
