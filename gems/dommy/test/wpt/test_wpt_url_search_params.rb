# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for URLSearchParams focusing on areas not exercised
# by test/test_url.rb's TestURLSearchParams class.
#
# WPT: url/urlsearchparams-sort.any.js,
#      url/urlsearchparams-stringifier.any.js,
#      url/urlsearchparams-foreach.any.js,
#      url/urlsearchparams-getall.any.js
# Spec: https://url.spec.whatwg.org/#interface-urlsearchparams

class TestWPTURLSearchParamsFormEncoding < Minitest::Test
  # WHATWG form-urlencoded parser: `+` decodes to space; percent-
  # encoded UTF-8 bytes decode to their character.

  def test_plus_decodes_to_space
    params = Dommy::URLSearchParams.new("a=hello+world")
    assert_equal("hello world", params.get("a"))
  end

  def test_percent_encoded_utf8_decodes
    params = Dommy::URLSearchParams.new("name=%E3%81%82")
    assert_equal("あ", params.get("name"))
  end

  def test_to_string_encodes_space_as_plus
    params = Dommy::URLSearchParams.new
    params.append("key with space", "value")
    assert_equal("key+with+space=value", params.to_s)
  end

  def test_to_string_percent_encodes_special_chars
    params = Dommy::URLSearchParams.new
    params.append("a", "b & c")
    assert_equal("a=b+%26+c", params.to_s)
  end
end

class TestWPTURLSearchParamsSort < Minitest::Test
  # WHATWG sort: compares names by code unit sequence. The relative
  # order of pairs with equal names must be preserved (stable sort).

  def test_sort_orders_ascii_keys
    params = Dommy::URLSearchParams.new("c=3&a=1&b=2")
    params.sort
    assert_equal(["a", "b", "c"], params.keys)
  end

  def test_sort_orders_non_ascii_after_ascii
    # In code-point order, ASCII letters precede `あ` (U+3042).
    params = Dommy::URLSearchParams.new
    params.append("z", "1")
    params.append("a", "2")
    params.append("あ", "3")
    params.sort
    assert_equal(["a", "z", "あ"], params.keys)
  end

  def test_sort_is_stable_for_equal_keys
    params = Dommy::URLSearchParams.new("a=1&a=2&a=3")
    params.sort
    assert_equal([["a", "1"], ["a", "2"], ["a", "3"]], params.entries)
  end
end

class TestWPTURLSearchParamsEmptyAndEdgeCases < Minitest::Test
  def test_empty_string_yields_no_pairs
    params = Dommy::URLSearchParams.new("")
    assert_equal(0, params.size)
    assert_equal([], params.entries)
  end

  def test_empty_key_is_kept
    params = Dommy::URLSearchParams.new("=a")
    assert_equal([["", "a"]], params.entries)
  end

  def test_empty_value_is_kept
    params = Dommy::URLSearchParams.new("b=")
    assert_equal([["b", ""]], params.entries)
  end

  def test_size_reflects_pair_count
    params = Dommy::URLSearchParams.new
    assert_equal(0, params.size)
    params.append("a", "1")
    assert_equal(1, params.size)
    params.append("a", "2")
    assert_equal(2, params.size)
  end
end

class TestWPTURLSearchParamsIteration < Minitest::Test
  # WHATWG: keys()/values()/entries() yield in insertion order,
  # including duplicates for repeated names.

  def test_keys_yields_all_including_duplicates
    params = Dommy::URLSearchParams.new("a=1&b=2&a=3")
    assert_equal(["a", "b", "a"], params.keys)
  end

  def test_values_yields_all_in_insertion_order
    params = Dommy::URLSearchParams.new("a=1&b=2&a=3")
    assert_equal(["1", "2", "3"], params.values)
  end

  def test_entries_yields_pairs_in_insertion_order
    params = Dommy::URLSearchParams.new("a=1&b=2&a=3")
    assert_equal([["a", "1"], ["b", "2"], ["a", "3"]], params.entries)
  end

  def test_for_each_callback_receives_value_key_self
    params = Dommy::URLSearchParams.new("a=1&b=2")
    captured = []
    params.for_each { |value, key, owner| captured << [value, key, owner.equal?(params)] }
    assert_equal([["1", "a", true], ["2", "b", true]], captured)
  end
end

class TestWPTURLSearchParamsGetAll < Minitest::Test
  # WHATWG: get_all returns *all* values matching a name, in
  # insertion order; get returns only the first.

  def test_get_returns_first_match
    params = Dommy::URLSearchParams.new("a=1&a=2&a=3")
    assert_equal("1", params.get("a"))
  end

  def test_get_all_returns_all_matches
    params = Dommy::URLSearchParams.new("a=1&a=2&a=3")
    assert_equal(["1", "2", "3"], params.get_all("a"))
  end

  def test_get_all_returns_empty_for_missing_name
    params = Dommy::URLSearchParams.new("a=1")
    assert_equal([], params.get_all("missing"))
  end
end
