# frozen_string_literal: true

require_relative "test_helper"

class TestClassList < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='foo bar'></div>")
    @el = @win.document.get_element_by_id("x")
    @list = @el.class_list
  end

  def test_contains_existing
    assert_equal(true, @list.__js_call__("contains", ["foo"]))
    assert_equal(true, @list.__js_call__("contains", ["bar"]))
  end

  def test_contains_missing
    assert_equal(false, @list.__js_call__("contains", ["nope"]))
  end

  def test_add_token
    @list.__js_call__("add", ["baz"])
    assert_equal("foo bar baz", @el.class_name)
  end

  def test_add_existing_is_idempotent
    @list.__js_call__("add", ["foo"])
    assert_equal("foo bar", @el.class_name)
  end

  def test_remove_token
    @list.__js_call__("remove", ["foo"])
    assert_equal("bar", @el.class_name)
  end

  def test_remove_missing_is_noop
    @list.__js_call__("remove", ["nope"])
    assert_equal("foo bar", @el.class_name)
  end

  def test_toggle_off_when_present
    assert_equal(false, @list.__js_call__("toggle", ["foo"]))
    refute(@list.__js_call__("contains", ["foo"]))
  end

  def test_toggle_on_when_absent
    assert_equal(true, @list.__js_call__("toggle", ["baz"]))
    assert(@list.__js_call__("contains", ["baz"]))
  end

  def test_toggle_force_true_keeps_token
    @list.__js_call__("toggle", ["foo", true])
    assert(@list.__js_call__("contains", ["foo"]))
  end

  def test_toggle_force_false_removes_token
    @list.__js_call__("toggle", ["foo", false])
    refute(@list.__js_call__("contains", ["foo"]))
  end

  def test_replace_present_token
    assert_equal(true, @list.__js_call__("replace", ["foo", "baz"]))
    assert_equal("baz bar", @el.class_name)
  end

  def test_replace_missing_token_is_noop
    assert_equal(false, @list.__js_call__("replace", ["nope", "baz"]))
    assert_equal("foo bar", @el.class_name)
  end

  # Regression: replace() must not mutate the cached token array in place. Doing
  # so left @token_cache keyed by the old raw class string but holding the
  # mutated tokens, so a second replace on the same element (with the same raw
  # value) read stale tokens. The WPT sequence below produced "a d" instead of
  # "a b" before the fix.
  def test_replace_does_not_corrupt_token_cache_across_calls
    @el.set_attribute("class", "a b c")
    assert_equal(true, @list.__js_call__("replace", ["b", "d"]))
    assert_equal("a d c", @el.class_name)

    @el.set_attribute("class", "a b c")
    assert_equal(true, @list.__js_call__("replace", ["c", "a"]))
    assert_equal("a b", @el.class_name)
  end
end
