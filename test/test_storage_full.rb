# frozen_string_literal: true

require_relative "test_helper"

# Round out Storage coverage to match happy-dom's reserved-key tests
# and key(i) semantics.
class TestStorageFull < Minitest::Test
  include DommyTestHelper

  def setup
    @storage = make_window.__js_get__("localStorage")
  end

  def test_key_returns_nth_name
    @storage.set_item("first", "1")
    @storage.set_item("second", "2")
    assert_equal("first", @storage.key(0))
    assert_equal("second", @storage.key(1))
  end

  def test_key_out_of_range
    @storage.set_item("only", "x")
    assert_nil(@storage.key(99))
  end

  def test_reserved_key_length_via_setItem
    # `storage.length` is a built-in property; `setItem("length", v)`
    # should store the value separately and not break the count.
    @storage.set_item("length", "stored")
    assert_equal("stored", @storage.get_item("length"))
    # The IDL property (`storage[:length]` / `__js_get__("length")`)
    # still returns the count.
    assert_equal(1, @storage.__js_get__("length"))
    assert_equal(1, @storage.length)
  end

  def test_reserved_key_getItem_takes_user_value
    @storage.set_item("getItem", "user")
    assert_equal("user", @storage.get_item("getItem"))
  end

  def test_get_item_missing_returns_nil
    assert_nil(@storage.get_item("absent"))
  end

  def test_set_item_overwrites_existing
    @storage.set_item("k", "v1")
    @storage.set_item("k", "v2")
    assert_equal("v2", @storage.get_item("k"))
  end

  def test_set_item_coerces_non_string_keys
    @storage.set_item(:sym, "s")
    @storage.set_item(42, "n")
    assert_equal("s", @storage.get_item("sym"))
    assert_equal("n", @storage.get_item("42"))
  end

  def test_clear_resets_length_to_zero
    3.times { |i| @storage.set_item("k#{i}", "v") }
    @storage.clear
    assert_equal(0, @storage.length)
    assert_nil(@storage.get_item("k0"))
  end

  def test_remove_item_no_op_when_key_absent
    @storage.remove_item("nothing")
    assert_equal(0, @storage.length)
  end
end
