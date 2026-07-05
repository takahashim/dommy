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

  SVG_NS = "http://www.w3.org/2000/svg"

  def test_declared_namespace_prefix_resolves_to_its_uri
    ast = SP.parse!("svg|rect", namespaces: {"svg" => SVG_NS})
    type = ast.selectors.first.parts.first.compound.type
    assert_equal SVG_NS, type.namespace
    assert_equal "rect", type.name
  end

  def test_default_namespace_applies_to_unprefixed_type
    ast = SP.parse!("rect", namespaces: {default: SVG_NS})
    assert_equal SVG_NS, ast.selectors.first.parts.first.compound.type.namespace
  end

  def test_undeclared_prefix_still_raises_with_a_namespace_map
    assert_raises(Dommy::DOMException::SyntaxError) do
      SP.parse!("other|rect", namespaces: {"svg" => SVG_NS})
    end
  end

  def test_namespace_prefix_resolves_inside_is_and_not
    ast = SP.parse!(":is(svg|rect, svg|circle)", namespaces: {"svg" => SVG_NS})
    refute_nil ast # resolves without raising
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

  def test_parse_returns_ast_and_specificity
    ast = SP.parse!("input:checked + label")
    assert_equal [0, 1, 2], ast.specificity.to_a

    ast = SP.parse!(":is(:checked, .x)")
    assert_equal [0, 1, 0], ast.specificity.to_a

    ast = SP.parse!("section:not(:has(h1, h2))")
    assert_equal [0, 0, 2], ast.specificity.to_a

    ast = SP.parse!(":nth-child(2n+1 of .x)")
    assert_equal [0, 2, 0], ast.specificity.to_a
  end

  # The AST cache must memoize failures too: a previously-seen invalid selector
  # still throws on repeat (not silently return a cached success/nil).
  def test_invalid_selector_still_raises_when_cached
    2.times do
      assert_raises(Dommy::DOMException::SyntaxError) { SP.parse!("div % p") }
    end
  end

  # A repeated valid parse returns an equivalent AST (cache hit path).
  def test_repeated_valid_parse_is_consistent
    first = SP.parse!("input:checked + label")
    second = SP.parse!("input:checked + label")
    assert_equal first.specificity.to_a, second.specificity.to_a
  end

  def test_is_and_where_are_forgiving
    assert SP.valid?(":is(.x, :unknown)")
    assert SP.valid?(":where(.x, :unknown)")
  end

  def test_not_and_has_are_not_forgiving
    refute SP.valid?(":not(.x, :unknown)")
    refute SP.valid?(":has(.x, :unknown)")
    refute SP.valid?(":has(:has(.x))")
    refute SP.valid?(":has(::before)")
  end

  # A forgiving selector list (`:is`/`:where`) whose every clause is invalid
  # is still a valid selector — it parses to an empty list and matches nothing.
  def test_forgiving_list_with_all_invalid_branches_is_valid_and_matches_nothing
    assert SP.valid?(":is(:unknown-xyz)")
    assert SP.valid?(":where(:unknown-xyz)")
    is_pseudo = SP.parse!(":is(:unknown-xyz)").selectors.first.rightmost.subclass_selectors.first
    assert_empty is_pseudo.argument.selectors

    doc = Dommy.parse('<div class="a"></div>').document
    assert_equal [], doc.query_selector_all(":is(:unknown-xyz)").to_a
    assert_equal [], doc.query_selector_all(":where(:unknown-xyz)").to_a

    # A valid branch still matches even when an invalid sibling is dropped.
    matched = doc.query_selector_all(":is(.a, :unknown-xyz)").to_a
    assert_equal 1, matched.length
    assert_equal "a", matched.first.get_attribute("class")
  end

  def test_non_forgiving_lists_still_reject_all_invalid_branches
    refute SP.valid?(":not(:unknown-xyz)")
    refute SP.valid?(":has(:unknown-xyz)")
  end

  # `:has(` appearing only inside a quoted attribute value is not a nested
  # `:has()`; only a structurally parsed `:has` inside `:has` is invalid.
  def test_has_nesting_is_detected_structurally_not_textually
    assert SP.valid?('div:has([title=":has(x)"])')
    refute SP.valid?(":has(:has(.x))")
    refute SP.valid?(":has(div :has(.x))")
  end

  # An+B: `<integer>` and `n` are one token, so `3 n` is invalid; whitespace
  # around the operator (`3n + 1`, `+ 3n`) stays valid.
  def test_an_plus_b_rejects_whitespace_between_integer_and_n
    refute SP.valid?(":nth-child(3 n)")
    refute SP.valid?(":nth-child(3 n + 1)")
    assert SP.valid?(":nth-child(3n + 1)")
    assert SP.valid?(":nth-child(+ 3n)")
    assert SP.valid?(":nth-child(3n)")
    assert SP.valid?(":nth-child( 2n - 1 )")
  end

  # A pseudo-element ends a compound selector: nothing may follow it.
  def test_pseudo_element_must_be_last_in_compound
    refute SP.valid?("div::before.foo")
    refute SP.valid?("div::before#x")
    refute SP.valid?("div::before[a]")
    refute SP.valid?("div::before:hover")
    refute SP.valid?("div::before::after")
    refute SP.valid?("p:first-line.foo") # legacy one-colon form too
    assert SP.valid?("div.foo::before")
    assert SP.valid?("div::before, .foo")
  end
end
