# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for CSS conditional rules: @supports applied through
# the cascade and CSS.supports(). Adapted (not mirrored): the WPT files use
# testharness.js to assert CSS.supports() return values and @supports rule
# application; the same behaviours are exercised here. Dommy has no feature
# database, so a syntactically valid feature query is treated as supported —
# the boolean structure (not/and/or, selector()) is what carries the logic.
#
# WPT: css/css-conditional/at-supports-*.html,
#      css/css-conditional/idlharness, css/cssom/cssomstyledeclaration-*
# Spec: https://drafts.csswg.org/css-conditional-3/#at-supports,
#       https://drafts.csswg.org/css-conditional-3/#the-css-namespace
class TestWPTCssConditional < Minitest::Test
  def setup
    @css = Dommy::CSSNamespace.new
  end

  def supports(*args)
    @css.__js_call__("supports", args)
  end

  def computed(html, id = "t")
    document = Dommy.parse(html).document
    document.default_view.get_computed_style(document.get_element_by_id(id))
  end

  # --- CSS.supports(conditionText) --------------------------------------

  def test_supports_simple_feature_query
    assert supports("(display: flex)")
    refute supports("(display:)")
  end

  def test_supports_not_and_or
    refute supports("not (display: flex)")
    assert supports("(display: flex) and (color: red)")
    assert supports("(display: flex) or (foo: bar)")
    refute supports("(display:) and (color: red)")
  end

  def test_supports_requires_parentheses_in_one_argument_form
    # css-conditional-3: the 1-arg form is a <supports-condition>, which is
    # parenthesised; a bare declaration is not a valid condition.
    refute supports("display: flex")
  end

  def test_supports_selector_function
    assert supports("selector(a:hover)")
    assert supports("selector(:is(.a, .b))")
    refute supports("selector(:::bogus)")
  end

  # --- CSS.supports(property, value) ------------------------------------

  def test_supports_two_argument_declaration_form
    assert supports("display", "flex")
    refute supports("display", "")
  end

  # --- @supports rules in the cascade -----------------------------------

  def test_supported_block_applies
    cs = computed('<style>@supports (display: grid) { #t { color: red } }</style><p id="t">x</p>')
    assert_equal "rgb(255, 0, 0)", cs["color"]
  end

  def test_unsupported_negation_block_is_skipped
    cs = computed('<style>@supports not (display: grid) { #t { color: red } }</style><p id="t">x</p>')
    assert_equal "rgb(0, 0, 0)", cs["color"]
  end

  def test_supports_and_or_in_at_rule
    document = Dommy.parse(<<~HTML).document
      <style>
        @supports (display: grid) and (color: red) { #a { color: red } }
        @supports (display: grid) or (frobnicate: 9) { #b { color: red } }
      </style>
      <p id="a">a</p><p id="b">b</p>
    HTML
    view = document.default_view
    assert_equal "rgb(255, 0, 0)", view.get_computed_style(document.get_element_by_id("a"))["color"]
    assert_equal "rgb(255, 0, 0)", view.get_computed_style(document.get_element_by_id("b"))["color"]
  end
end
