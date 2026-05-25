# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Fetch API Headers.
# WPT: fetch/api/headers/headers-basic.any.js,
#      fetch/api/headers/headers-case.any.js
# Spec: https://fetch.spec.whatwg.org/#headers-class
#
# No existing test file targets Headers directly; this fills the gap.
# Some Dommy-specific deviations from the WHATWG spec are documented
# inline (notably `has` is *not* case-insensitive in this implementation).
class TestWPTHeadersGet < Minitest::Test
  # Dommy's Headers#get implements case-insensitivity by canonicalizing
  # the lookup name to Title-Case (`content-type` -> `Content-Type`) and
  # retrying. This covers the common case of stub fixtures storing
  # canonical names.

  def test_get_returns_value_for_exact_match
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal("text/plain", h.__js_call__("get", ["Content-Type"]))
  end

  def test_get_is_case_insensitive_via_canonical_fallback
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
  # Dommy-specific: `has` performs an *exact* key match without the
  # canonical fallback that `get` uses. Code that relies on
  # case-insensitive existence checking should canonicalize the name
  # before querying, or use `get` and check for nil.

  def test_has_returns_true_for_exact_match
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal(true, h.__js_call__("has", ["Content-Type"]))
  end

  def test_has_returns_false_for_missing_name
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal(false, h.__js_call__("has", ["X-Missing"]))
  end

  def test_has_does_not_apply_canonical_fallback
    # Dommy deviation: WHATWG spec defines `has` as case-insensitive.
    # Dommy's implementation checks `@hash.key?(name)` against the
    # original storage casing only.
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal(false, h.__js_call__("has", ["content-type"]))
  end
end

class TestWPTHeadersEntries < Minitest::Test
  def test_entries_returns_array_of_pairs
    h = Dommy::Headers.new("Content-Type" => "text/plain", "X-Foo" => "bar")
    assert_equal([["Content-Type", "text/plain"], ["X-Foo", "bar"]],
                 h.__js_call__("entries", []))
  end

  def test_entries_for_empty_headers
    h = Dommy::Headers.new({})
    assert_equal([], h.__js_call__("entries", []))
  end

  def test_entries_preserves_insertion_order
    h = Dommy::Headers.new("Z-Last" => "1", "A-First" => "2")
    keys = h.__js_call__("entries", []).map(&:first)
    assert_equal(["Z-Last", "A-First"], keys)
  end
end

class TestWPTHeadersForEach < Minitest::Test
  # WHATWG spec passes `(value, key, headers)` to the callback. Dommy
  # passes `(value, key)` only; the third argument is omitted. This
  # is sufficient for most consumers but is a known deviation.

  def test_for_each_invokes_callback_for_each_pair
    h = Dommy::Headers.new("Content-Type" => "text/plain", "X-Foo" => "bar")
    seen = []
    cb = proc { |value, key| seen << [key, value] }
    h.__js_call__("forEach", [cb])
    assert_equal([["Content-Type", "text/plain"], ["X-Foo", "bar"]], seen)
  end

  def test_for_each_does_not_invoke_for_empty_headers
    h = Dommy::Headers.new({})
    called = false
    cb = proc { |_, _| called = true }
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
  def test_string_keyed_hash_is_stored_directly
    h = Dommy::Headers.new("Content-Type" => "text/plain")
    assert_equal({"Content-Type" => "text/plain"}, h.to_h)
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
    copy["X-Foo"] = "modified"
    assert_equal("bar", h.__js_call__("get", ["X-Foo"]))
  end
end
