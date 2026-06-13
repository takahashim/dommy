# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for CSS Custom Properties (var()). Adapted (not
# mirrored): the WPT files assert getComputedStyle after var() substitution.
#
# WPT: css/css-variables/variable-*.html, css/css-variables/var-*.html
# Spec: https://drafts.csswg.org/css-variables/
class TestWPTCssVariables < Minitest::Test
  def value(html, prop, id = "t")
    document = Dommy.parse(html).document
    document.default_view.get_computed_style(document.get_element_by_id(id))[prop]
  end

  def test_basic_substitution
    assert_equal "rgb(255, 0, 0)", value('<style>#t { --c: red; color: var(--c) }</style><p id="t">x</p>', "color")
  end

  # css-variables §3: custom properties inherit by default.
  def test_custom_properties_inherit
    html = '<style>#outer { --c: red } #t { color: var(--c) }</style><div id="outer"><p id="t">x</p></div>'
    assert_equal "rgb(255, 0, 0)", value(html, "color")
  end

  # §4: var() fallback used when the variable is not set.
  def test_fallback_when_unset
    assert_equal "rgb(0, 0, 255)", value('<style>#t { color: var(--missing, blue) }</style><p id="t">x</p>', "color")
  end

  def test_fallback_may_contain_commas
    assert_equal "rgb(1, 2, 3)", value('<style>#t { color: var(--missing, rgb(1, 2, 3)) }</style><p id="t">x</p>', "color")
  end

  # §3: a chained reference resolves transitively.
  def test_nested_reference
    assert_equal "rgb(0, 0, 255)", value('<style>#t { --a: blue; --b: var(--a); color: var(--b) }</style><p id="t">x</p>', "color")
  end

  # §3: a cyclic reference is guaranteed-invalid; the property uses its
  # fallback / unset value.
  def test_cycle_is_invalid
    html = '<style>#t { --a: var(--b); --b: var(--a); color: var(--a, green) }</style><p id="t">x</p>'
    assert_equal "rgb(0, 128, 0)", value(html, "color")
  end

  # §3: substitution happens before shorthand expansion.
  def test_substitution_into_shorthand
    html = '<style>#t { --w: 2px; border: var(--w) solid red }</style><p id="t">x</p>'
    assert_equal "2px", value(html, "border-top-width")
  end

  # An invalid var() substitution makes the declaration behave as unset.
  def test_invalid_substitution_is_unset
    html = '<style>div { color: red } #t { --x:; color: var(--x) }</style><div><p id="t">x</p></div>'
    # --x is empty (guaranteed-invalid) -> color: unset -> inherits red.
    assert_equal "rgb(255, 0, 0)", value(html, "color")
  end
end
