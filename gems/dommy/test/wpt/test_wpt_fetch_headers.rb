# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Fetch API Headers.
# WPT: fetch/api/headers/headers-basic.any.js,
#      fetch/api/headers/headers-case.any.js
# Spec: https://fetch.spec.whatwg.org/#headers-class
#
# No existing test file targets Headers directly; this fills the gap.
# Names are stored lowercased and compared case-insensitively; iteration
# is sorted by name (the WHATWG "sort and combine" output).
class TestWPTHeadersGet < Minitest::Test
  # WHATWG: header names are case-insensitive. Dommy stores them lowercased,
  # so a lookup of any casing resolves the same value.

  def test_get_returns_value_for_exact_match
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal("text/plain", h.__js_call__("get", ["Content-Type"]))
  end

  def test_get_is_case_insensitive
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal("text/plain", h.__js_call__("get", ["content-type"]))
    assert_equal("text/plain", h.__js_call__("get", ["CONTENT-TYPE"]))
  end

  def test_get_returns_nil_for_missing_name
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_nil(h.__js_call__("get", ["X-Missing"]))
  end
end

class TestWPTHeadersHas < Minitest::Test
  # Per WHATWG, `has` is case-insensitive (lowercased lookup).

  def test_has_returns_true_for_exact_match
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal(true, h.__js_call__("has", ["Content-Type"]))
  end

  def test_has_returns_false_for_missing_name
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal(false, h.__js_call__("has", ["X-Missing"]))
  end

  def test_has_is_case_insensitive
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal(true, h.__js_call__("has", ["content-type"]))
    assert_equal(true, h.__js_call__("has", ["CONTENT-TYPE"]))
  end
end

class TestWPTHeadersEntries < Minitest::Test
  # WHATWG "sort and combine": names are lowercased and iterated in sorted
  # order. (WPT: headers-basic.any.js — "Check sorted output").

  def test_entries_returns_lowercased_sorted_pairs
    h = Dommy::Headers.new("Content-Type" => "text/plain", "X-Foo" => "bar")
    assert_equal([["content-type", "text/plain"], ["x-foo", "bar"]],
                 h.__js_call__("entries", []))
  end

  def test_entries_for_empty_headers
    h = Dommy::Headers.new({})
    assert_equal([], h.__js_call__("entries", []))
  end

  def test_entries_are_sorted_by_name
    h = Dommy::Headers.new("Z-Last" => "1", "A-First" => "2")
    keys = h.__js_call__("entries", []).map(&:first)
    assert_equal(["a-first", "z-last"], keys)
  end
end

class TestWPTHeadersForEach < Minitest::Test
  # WHATWG spec: forEach(callback) invokes the callback with
  # (value, key, headers) for each pair, in sorted (lowercased) order.

  def test_for_each_invokes_callback_for_each_pair
    h = Dommy::Headers.new("Content-Type" => "text/plain", "X-Foo" => "bar")
    seen = []
    cb = proc { |value, key, _h| seen << [key, value] }
    h.__js_call__("forEach", [cb])
    assert_equal([["content-type", "text/plain"], ["x-foo", "bar"]], seen)
  end

  def test_for_each_passes_headers_as_third_argument
    h = Dommy::Headers.new("X-Foo" => "bar")
    captured = nil
    cb = proc { |_value, _key, headers| captured = headers }
    h.__js_call__("forEach", [cb])
    assert_same(h, captured)
  end

  def test_for_each_does_not_invoke_for_empty_headers
    h = Dommy::Headers.new({})
    called = false
    cb = proc { |_, _, _| called = true }
    h.__js_call__("forEach", [cb])
    refute(called)
  end
end

class TestWPTHeadersCanonical < Minitest::Test
  # Dommy.Headers.canonical normalizes a header name to RFC 7230's
  # canonical Title-Case form (each `-`-separated segment capitalized).

  def test_canonical_capitalizes_lowercase
    assert_equal("Content-Type", Dommy::Headers.canonical("content-type"))
  end

  def test_canonical_recapitalizes_uppercase
    assert_equal("X-My-Header", Dommy::Headers.canonical("X-MY-HEADER"))
  end

  def test_canonical_single_word
    assert_equal("Accept", Dommy::Headers.canonical("accept"))
  end

  def test_canonical_already_canonical
    assert_equal("Content-Length", Dommy::Headers.canonical("Content-Length"))
  end
end

class TestWPTHeadersConstruction < Minitest::Test
  # WHATWG "fill": a record (Hash) sets each key; names are lowercased.
  def test_record_hash_is_lowercased
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal({"content-type" => "text/plain"}, h.to_h)
  end

  def test_symbol_keyed_hash_is_normalized_to_strings
    h = Dommy::Headers.new(content_type: "text/plain")
    assert_equal({"content_type" => "text/plain"}, h.to_h)
  end

  def test_non_hash_input_yields_empty_headers
    h = Dommy::Headers.new(nil)
    assert_equal({}, h.to_h)
  end

  def test_to_h_returns_a_copy
    h = Dommy::Headers.new("X-Foo" => "bar")
    copy = h.to_h
    copy["x-foo"] = "modified"
    assert_equal("bar", h.__js_call__("get", ["X-Foo"]))
  end

  # WHATWG "fill": a sequence (array of pairs) appends each pair, so a
  # repeated name combines its values with ", ".
  def test_sequence_of_pairs_appends
    h = Dommy::Headers.new([["X-A", "1"], ["x-a", "2"], ["X-B", "3"]])
    assert_equal("1, 2", h.__js_call__("get", ["x-a"]))
    assert_equal("3", h.__js_call__("get", ["x-b"]))
  end

  # `new Headers(otherHeaders)` copies an existing Headers instance.
  def test_headers_instance_is_copied
    src = Dommy::Headers.new("X-Foo" => "bar")
    h = Dommy::Headers.new(src)
    assert_equal("bar", h.__js_call__("get", ["x-foo"]))
  end
end

class TestWPTHeadersAppend < Minitest::Test
  # WHATWG: append combines values for an existing (case-insensitive) name.
  def test_append_combines_existing_value
    h = Dommy::Headers.new("Accept" => "text/html")
    h.__js_call__("append", ["accept", "application/json"])
    assert_equal("text/html, application/json", h.__js_call__("get", ["Accept"]))
  end

  def test_append_creates_when_absent
    h = Dommy::Headers.new({})
    h.__js_call__("append", ["X-New", "1"])
    assert_equal("1", h.__js_call__("get", ["x-new"]))
  end

  def test_set_overwrites
    h = Dommy::Headers.new("X-A" => "1")
    h.__js_call__("set", ["x-a", "2"])
    assert_equal("2", h.__js_call__("get", ["X-A"]))
  end

  def test_get_set_cookie_returns_list
    h = Dommy::Headers.new("Set-Cookie" => "a=1")
    assert_equal(["a=1"], h.__js_call__("getSetCookie", []))
    assert_equal([], Dommy::Headers.new({}).__js_call__("getSetCookie", []))
  end
end
