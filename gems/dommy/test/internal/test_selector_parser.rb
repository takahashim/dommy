# frozen_string_literal: true

require_relative "../test_helper"

# Validates the CSS Selectors grammar parser that backs
# querySelector/querySelectorAll/matches/closest's SyntaxError behaviour.
class TestSelectorParser < Minitest::Test
  SP = Dommy::Internal::SelectorParser

  # Selectors the spec (and the WPT Selectors-API corpus) require to throw.
  INVALID = [
    "", "[", "]", "(", ")", "{", "}", "<", ">",
    "#", "div,", ".", ".5cm", "..test", ".foo..quux", ".bar.",
    "div % address, p", "div ++ address, p", "div ~~ address, p",
    "[*=test]", "[*|*=test]", "[class= space unquoted ]",
    "div:example", ":example", "div:linkexample",
    "div::example", "::example", ":::before", ":: before",
    "ns|div", ":not(ns|div)", "^|div", "$|div", ">*"
  ].freeze

  # A representative slice of selectors that must parse cleanly.
  VALID = [
    "*", "div", "div p", "div > p", "p + p", "p ~ p", "div, p",
    ".class-p", "#id", "[align]", "[type=text]", '[type="text" i]',
    "[class^=apple]", "[class*=' apple']", "[class$=apple ]", '[rel~="book mark"]',
    "[lang|=en]", "*|div", "|div", "|*", "*|*", "[*|TiTlE]",
    ":root", ":target", ":not(*)", ":not(*|*)", ":not( div )", ":not(:first-child)",
    ":nth-child(2n+1)", ":nth-of-type(2n)", ":nth-last-child(odd)", ":first-child",
    "p:empty", ":lang(en)", "::before", "::after", "::first-line", "::slotted(foo)",
    ":link:visited", ".foo\\:bar", "#\\#foo\\:bar", ".test\\.foo\\[5\\]bar",
    ".台北", "#台北", "[data-attr-value=中文]",
    "[align=\"center\"", "::slotted(foo", # EOF implicitly closes brackets/parens
    "#a>>#b" # `>>` legacy descendant combinator (accepted, treated as descendant)
  ].freeze

  def test_invalid_selectors_raise_syntax_error
    INVALID.each do |sel|
      assert_raises(Dommy::DOMException::SyntaxError, "expected #{sel.inspect} to be invalid") do
        SP.validate!(sel)
      end
    end
  end

  def test_valid_selectors_do_not_raise
    VALID.each do |sel|
      SP.validate!(sel)
    rescue Dommy::DOMException::SyntaxError => e
      flunk "expected #{sel.inspect} to be valid, got: #{e.message}"
    end
  end

  def test_validate_returns_the_selector
    assert_equal "div.foo", SP.validate!("div.foo")
  end

  def test_valid_predicate
    assert SP.valid?("div > p")
    refute SP.valid?("div % p")
  end

  # matchable_selector drops clauses whose subject is a pseudo-element (they
  # match no element) and leaves everything else untouched.
  def test_matchable_selector_drops_pseudo_element_clauses
    assert_equal ":not(*)", SP.matchable_selector("::before")
    assert_equal ":not(*)", SP.matchable_selector("#x:first-line") # legacy one-colon
    assert_equal ":not(*)", SP.matchable_selector("p::after")
    assert_equal "div", SP.matchable_selector("div, ::before")
    assert_equal "div, p", SP.matchable_selector("div, ::before, p")
  end

  def test_matchable_selector_leaves_ordinary_selectors_untouched
    ["div", "#id .cls", "a:hover", ":not(.x)", "[type=text]", "p:first-child"].each do |sel|
      assert_equal sel, SP.matchable_selector(sel), sel
    end
  end
end
