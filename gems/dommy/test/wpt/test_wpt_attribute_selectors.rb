# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for attribute selectors and their matchers. Adapted
# (not mirrored): the WPT files are testharness.js pages calling
# querySelectorAll with each matcher; the same matrix runs against Dommy's AST
# matcher. Notable spec corners: substring matchers against the empty string
# never match, and the case-sensitivity flags.
#
# WPT: css/selectors/attribute-selectors/, dom/nodes/ParentNode-querySelector-*
# Spec: https://drafts.csswg.org/selectors-4/#attribute-selectors
class TestWPTAttributeSelectors < Minitest::Test
  def ids(html, selector)
    Dommy.parse(html).document.query_selector_all(selector).map { |el| el.get_attribute("id") }.compact
  end

  def test_presence_and_exact
    html = '<a id="a" href="x"></a><a id="b"></a>'
    assert_equal %w[a], ids(html, "[href]")
    assert_equal %w[a], ids(html, '[href="x"]')
    assert_equal [], ids(html, '[href="y"]')
  end

  # §6.1 [attr~=val]: a whitespace-separated word list contains val.
  def test_whitespace_list_matcher
    html = '<p id="a" class="foo bar baz"></p><p id="b" class="foobar"></p>'
    assert_equal %w[a], ids(html, "[class~=bar]")
    assert_equal [], ids(html, "[class~=foobar2]")
  end

  # §6.1 [attr|=val]: equal to val or starts with "val-".
  def test_hyphen_matcher
    html = '<p id="a" lang="en-US"></p><p id="b" lang="en"></p><p id="c" lang="fr"></p>'
    assert_equal %w[a b], ids(html, "[lang|=en]")
  end

  # §6.2 substring matchers.
  def test_prefix_suffix_substring_matchers
    html = '<a id="a" href="https://example.com/x.pdf"></a><a id="b" href="http://x.txt"></a>'
    assert_equal %w[a], ids(html, "[href^=https]")
    assert_equal %w[a], ids(html, '[href$=".pdf"]')
    assert_equal %w[a b], ids(html, "[href*=x]")
  end

  # §6.2: a substring matcher against the empty string never matches.
  def test_empty_string_substring_matchers_match_nothing
    html = '<a id="a" href="x"></a>'
    assert_equal [], ids(html, '[href^=""]')
    assert_equal [], ids(html, '[href$=""]')
    assert_equal [], ids(html, '[href*=""]')
  end

  # §6.3 case-sensitivity: `i` forces ASCII case-insensitive, `s` case-sensitive.
  def test_case_sensitivity_flags
    html = '<p id="a" data-x="ABC"></p>'
    assert_equal %w[a], ids(html, "[data-x=abc i]")
    assert_equal [], ids(html, "[data-x=abc s]")
    assert_equal [], ids(html, "[data-x=abc]") # attribute values default to case-sensitive
  end

  # Attribute names are ASCII case-insensitive in HTML documents.
  def test_attribute_name_is_case_insensitive_in_html
    assert_equal %w[a], ids('<p id="a" TITLE="t"></p>', "[title]")
    assert_equal %w[a], ids('<p id="a" data-X="t"></p>', "[data-x]")
  end
end
