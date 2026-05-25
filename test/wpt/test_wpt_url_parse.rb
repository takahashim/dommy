# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the static URL.parse() and URL.canParse() methods.
# WPT: url/url-statics-parse.any.js, url/url-statics-canparse.any.js
# Spec: https://url.spec.whatwg.org/#url-statics
#
# These are the non-throwing counterparts to `new URL(...)`. `parse`
# returns nil on failure (where the constructor would raise
# DOMException::SyntaxError); `canParse` returns the same as a boolean.
class TestWPTURLParse < Minitest::Test
  def test_parse_returns_url_for_valid_absolute
    url = Dommy::URL.parse("https://example.test/a")
    assert_instance_of(Dommy::URL, url)
    assert_equal("https://example.test/a", url.href)
  end

  def test_parse_returns_nil_for_invalid_input
    assert_nil(Dommy::URL.parse("not a url"))
  end

  def test_parse_resolves_relative_against_base
    url = Dommy::URL.parse("/x", "https://example.test/")
    assert_instance_of(Dommy::URL, url)
    assert_equal("https://example.test/x", url.href)
  end

  def test_parse_returns_nil_when_relative_without_base
    assert_nil(Dommy::URL.parse("/x"))
  end

  def test_parse_returns_nil_when_base_is_invalid
    # Relative input + invalid base — both required to be valid.
    assert_nil(Dommy::URL.parse("/x", "not a url"))
  end
end

class TestWPTURLCanParse < Minitest::Test
  def test_can_parse_true_for_valid_absolute
    assert_equal(true, Dommy::URL.can_parse("https://example.test/"))
  end

  def test_can_parse_false_for_invalid_input
    assert_equal(false, Dommy::URL.can_parse("not a url"))
  end

  def test_can_parse_true_for_relative_with_base
    assert_equal(true, Dommy::URL.can_parse("/x", "https://example.test/"))
  end

  def test_can_parse_false_for_relative_without_base
    assert_equal(false, Dommy::URL.can_parse("/x"))
  end
end

class TestWPTURLParseJSBridge < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @ctor = @win.__js_get__("URL")
  end

  # The constructor object exposes `parse` and `canParse` as static
  # methods via `define_class_method`. This is what `URL.parse(...)`
  # resolves to in user JS.

  def test_js_bridge_parse_returns_url
    url = @ctor.__js_call__("parse", ["https://example.test/a"])
    assert_instance_of(Dommy::URL, url)
    assert_equal("https://example.test/a", url.href)
  end

  def test_js_bridge_parse_returns_nil_for_invalid
    assert_nil(@ctor.__js_call__("parse", ["not a url"]))
  end

  def test_js_bridge_can_parse_true
    assert_equal(true, @ctor.__js_call__("canParse", ["https://example.test/"]))
  end

  def test_js_bridge_can_parse_false
    assert_equal(false, @ctor.__js_call__("canParse", ["not a url"]))
  end
end
