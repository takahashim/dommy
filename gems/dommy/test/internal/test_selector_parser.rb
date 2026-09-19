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

  # An+B is written in tokens: `3n` is one dimension-token, `-n` one
  # ident-token, and a sign belongs to the token it precedes. So whitespace
  # inside any of those (`3 n`, `- n`, `+ 3n`) breaks the production, while
  # whitespace around the operator before the B part (`3n + 1`) is allowed.
  def test_an_plus_b_is_read_in_tokens
    refute SP.valid?(":nth-child(3 n)")
    refute SP.valid?(":nth-child(3 n + 1)")
    refute SP.valid?(":nth-child(- n)")
    refute SP.valid?(":nth-child(+ 3n)")
    refute SP.valid?(":nth-child(- 2)")
    assert SP.valid?(":nth-child(3n + 1)")
    assert SP.valid?(":nth-child(+3n)")
    assert SP.valid?(":nth-child(-n)")
    assert SP.valid?(":nth-child(-n+2)")
    assert SP.valid?(":nth-child(3n)")
    assert SP.valid?(":nth-child( 2n - 1 )")
  end

  # css-syntax-3 §4.3.11: after a leading U+002D, a second one starts the ident
  # too — which is how a custom property's name is written as a selector.
  def test_an_ident_can_start_with_two_hyphens
    assert SP.valid?(".--foo")
    assert SP.valid?("#--x")
    assert SP.valid?("[--data]")
    refute SP.valid?(".-")
    refute SP.valid?(".-1")
  end

  # §4.3.7: a backslash with nothing after it is a parse error whose value is
  # U+FFFD, not a failure to parse.
  def test_a_backslash_at_the_end_of_the_input_is_the_replacement_character
    ast = SP.parse!(".a\\")
    class_selector = ast.selectors.first.rightmost.subclass_selectors.first

    assert_equal "a\uFFFD", class_selector.value
  end

  # §3.3 filters the input before the tokenizer runs: a NULL becomes U+FFFD,
  # which is itself an ident code point. So `.a<NUL>b` names a class.
  def test_null_is_filtered_to_the_replacement_character
    ast = SP.parse!(".a\u0000b")
    class_selector = ast.selectors.first.rightmost.subclass_selectors.first

    assert_equal "a\uFFFDb", class_selector.value
  end

  # §4.2's non-ASCII ident code points are a list, not "everything from U+0080
  # up": U+2603 SNOWMAN falls between two of its ranges, so it can only be
  # written escaped.
  def test_non_ascii_ident_code_points_are_a_list
    assert SP.valid?(".\u00E9")  # LATIN SMALL LETTER E WITH ACUTE
    assert SP.valid?(".\u3042")  # HIRAGANA LETTER A
    assert SP.valid?(".\\2603 ") # the escaped form of the one below
    refute SP.valid?(".\u2603")  # SNOWMAN
  end

  # Selectors §5.1: an id selector's hash-token must carry an identifier, so the
  # "unrestricted" hash of `#1` is not one.
  def test_an_id_selector_needs_an_identifier
    assert SP.valid?("#vv")
    assert SP.valid?("#\\31 23")
    refute SP.valid?("#1")
    refute SP.valid?("#1x")
  end

  # css-syntax-3 §5.4.7 closes an open block when the input ends, so a selector
  # cut short mid-block is still read (`:not(` stays invalid — its argument is
  # then empty, and it is not forgiving).
  def test_an_unclosed_block_is_closed_at_the_end_of_the_input
    assert SP.valid?("a[href")
    assert SP.valid?("a[href='x'")
    assert SP.valid?(":is(")
    assert SP.valid?(":is(p")
    refute SP.valid?("p:not(")
    refute SP.valid?("div{")
  end

  # §4.3.2: a comment produces no token, so it can sit between any two tokens —
  # but it is not whitespace, so it cannot stand in for a descendant combinator.
  def test_comments_are_removed_by_the_tokenizer
    assert SP.valid?("/* c */ div")
    assert SP.valid?("div /* c */ p")
    assert SP.valid?("div /*x*/ /*y*/ p")
    assert SP.valid?("/* a */div/* b */ p")
    assert SP.valid?(".a/* c */.b")
    assert SP.valid?("div /* unterminated")
    refute SP.valid?("div/* c */p")
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
