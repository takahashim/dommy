# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for CSSOM resolved values returned by
# getComputedStyle. Adapted (not mirrored verbatim): the WPT files are
# testharness.js pages asserting getComputedStyle(el)[prop]; here the same
# assertions run against Dommy's resolved-value pipe. Layout-dependent
# resolved values (used values for width/height/margin %, etc.) are out of
# scope — Dommy returns computed values.
#
# WPT: css/cssom/getComputedStyle-*.html,
#      css/cssom/serialize-values.html, css/css-color/parsing/*
# Spec: https://drafts.csswg.org/cssom/#resolved-values,
#       https://drafts.csswg.org/css-color-4/#serializing-color-values,
#       https://drafts.csswg.org/css-values-4/#lengths
class TestWPTCssomComputedStyle < Minitest::Test
  def computed(html, id = "t")
    document = Dommy.parse(html).document
    document.default_view.get_computed_style(document.get_element_by_id(id))
  end

  def value(decls, prop, id_styles: "", element: "p")
    cs = computed("<style>#t { #{decls} }#{id_styles}</style><#{element} id=\"t\">x</#{element}>")
    cs[prop]
  end

  # css-color-4 §15: computed colors serialize as rgb()/rgba().
  def test_named_hex_and_rgb_colors_serialize_to_rgb
    assert_equal "rgb(255, 0, 0)", value("color: red", "color")
    assert_equal "rgb(0, 255, 0)", value("color: #00ff00", "color")
    assert_equal "rgb(0, 0, 255)", value("color: rgb(0, 0, 255)", "color")
    assert_equal "rgb(102, 51, 153)", value("color: rebeccapurple", "color")
  end

  def test_transparent_serializes_as_rgba_zero
    assert_equal "rgba(0, 0, 0, 0)", value("background-color: transparent", "background-color")
  end

  # css-values-4 §5: absolute lengths resolve to px (96px per inch). 1cm =
  # 10mm = 40Q.
  def test_absolute_lengths_resolve_to_px
    assert_equal "16px", value("text-indent: 12pt", "text-indent")
    assert_equal "96px", value("text-indent: 1in", "text-indent")
    assert_equal "37.795px", value("text-indent: 1cm", "text-indent")
    assert_equal "37.795px", value("text-indent: 10mm", "text-indent")
    assert_equal "37.795px", value("text-indent: 40Q", "text-indent")
  end

  # css-color-4 §13: opacity computes to a number clamped to [0, 1]; a
  # percentage maps to that fraction.
  def test_opacity_is_clamped
    assert_equal "1", value("opacity: 2", "opacity")
    assert_equal "0", value("opacity: -1", "opacity")
    assert_equal "0.5", value("opacity: 50%", "opacity")
    assert_equal "0.25", value("opacity: 0.25", "opacity")
  end

  # css-values-4 §6.1: font-relative em/rem against computed font sizes.
  def test_em_and_rem_resolve_against_font_sizes
    cs = computed(<<~HTML)
      <style>
        :root { font-size: 16px }
        #t { font-size: 20px; letter-spacing: 2em; text-indent: 2rem }
      </style>
      <p id="t">x</p>
    HTML
    assert_equal "40px", cs["letter-spacing"] # 2 * own 20px
    assert_equal "32px", cs["text-indent"]    # 2 * root 16px
  end

  # css-values-4 §6.2: viewport-percentage lengths against the viewport.
  def test_viewport_lengths_resolve_against_the_viewport
    # default Dommy viewport is 1280x720
    assert_equal "128px", value("font-size: 10vw", "font-size")
    assert_equal "72px", value("letter-spacing: 10vh", "letter-spacing")
  end

  # css-fonts-4: font-weight keywords compute to numbers.
  def test_font_weight_keywords_compute_to_numbers
    assert_equal "700", value("font-weight: bold", "font-weight")
    assert_equal "400", value("font-weight: normal", "font-weight")
  end

  # css2 §10.8.1: percentage line-height resolves to px; a unitless number
  # stays unitless (it inherits and scales per descendant font-size).
  def test_line_height_percentage_and_number
    assert_equal "30px", value("font-size: 20px; line-height: 150%", "line-height")
    assert_equal "1.5", value("font-size: 20px; line-height: 1.5", "line-height")
    assert_equal "normal", value("line-height: normal", "line-height")
  end

  # css-color-4 §15: currentColor resolves to the element's computed color.
  def test_currentcolor_resolves_to_color
    cs = computed('<style>#t { color: red; background-color: currentColor }</style><p id="t">x</p>')
    assert_equal "rgb(255, 0, 0)", cs["background-color"]
  end

  # css-backgrounds-3 / css-flexbox-1: shorthands expose their longhands in
  # the resolved style.
  def test_border_shorthand_longhands_are_resolved
    cs = computed('<style>#t { border: 2px solid red }</style><p id="t">x</p>')
    assert_equal "2px", cs["border-top-width"]
    assert_equal "solid", cs["border-bottom-style"]
    assert_equal "rgb(255, 0, 0)", cs["border-left-color"]
  end

  def test_flex_shorthand_longhands_are_resolved
    cs = computed('<style>#t { flex: 2 0 30% }</style><p id="t">x</p>')
    assert_equal "2", cs["flex-grow"]
    assert_equal "0", cs["flex-shrink"]
    assert_equal "30%", cs["flex-basis"]
  end

  # cssom §6.1: an element not in the document has an empty computed style.
  def test_disconnected_element_has_empty_computed_style
    document = Dommy.parse("<p>x</p>").document
    el = document.create_element("span")
    assert_equal "", document.default_view.get_computed_style(el)["color"]
  end

  # getComputedStyle(el, pseudo) exposes the cascaded computed declaration for
  # the standard pseudo-elements (no box generation, just the cascade).
  def test_pseudo_element_computed_styles
    %w[::before ::after ::first-line ::first-letter ::marker ::selection ::placeholder].each do |pseudo|
      document = Dommy.parse("<style>#t#{pseudo} { color: red }</style><p id=\"t\">x</p>").document
      cs = document.default_view.get_computed_style(document.get_element_by_id("t"), pseudo)
      assert_equal "rgb(255, 0, 0)", cs["color"], "expected #{pseudo} to cascade"
    end
  end

  def test_unknown_pseudo_element_is_empty
    document = Dommy.parse('<style>#t::bogus { color: red }</style><p id="t">x</p>').document
    cs = document.default_view.get_computed_style(document.get_element_by_id("t"), "::bogus")
    assert_equal "", cs["color"]
  end
end
