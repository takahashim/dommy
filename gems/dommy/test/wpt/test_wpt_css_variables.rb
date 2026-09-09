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

# `var()` takes a custom property name and then, optionally, a comma and a
# fallback. Anything else between the name and that comma is a syntax error, and
# a declaration whose value fails to parse is dropped rather than stored.
# WPT: css/css-variables/var-parsing.html
class TestWPTVarParsing < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @el = @win.document.create_element("div")
    @win.document.body.append_child(@el)
  end

  def width_after(value)
    @el.style.remove_property("width")
    @el.style.set_property("width", value)
    @el.style.get_property_value("width")
  end

  def test_the_shapes_var_accepts
    ["var(--x)", "var(--x,)", "var(--x, )", "var(--x, 1px)", "var(--a, var(--b))",
     "calc(var(--x) * 2)"].each { |value| assert_equal(value, width_after(value), value) }
  end

  def test_the_shapes_var_rejects
    ["var(--x ())", "var(--x () )", "var(--x() )", "var(--x (),)", "var(--x(),)"].each do |value|
      assert_equal("", width_after(value), value)
    end
  end

  def test_an_ordinary_value_is_untouched
    ["10px", "url(http://example.com/x.png)", "rgb(1, 2, 3)"].each do |value|
      assert_equal(value, width_after(value), value)
    end
  end

  # Setting a value the declaration block refuses, or removing a property that
  # was never set, changes nothing — so neither rewrites the style attribute.
  def test_a_rejected_write_leaves_the_attribute_alone
    @el.set_attribute("style", "z-index: 50; invalid")
    before = @el.get_attribute("style")
    @el.style.set_property("width", "var(--x ())")
    @el.style.remove_property("position")
    @el.style.set_property("position", "")
    assert_equal(before, @el.get_attribute("style"))
  end

  def test_setting_the_value_a_property_already_has_is_not_a_change
    @el.style.set_property("color", "red")
    @el.set_attribute("style", @el.get_attribute("style"))
    before = @el.get_attribute("style")
    @el.style.set_property("color", "red")
    assert_equal(before, @el.get_attribute("style"))
  end
end
