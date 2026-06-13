# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for computed color serialization. Adapted (not
# mirrored): the WPT parsing/serialization tests assert getComputedStyle of a
# color property; the same inputs run through Dommy's color normalization.
# Computed colors serialize as rgb()/rgba() (the legacy form browsers still
# return for resolved values).
#
# WPT: css/css-color/parsing/color-computed-*.html,
#      css/css-color/parsing/color-valid-*.html
# Spec: https://drafts.csswg.org/css-color-4/#serializing-color-values
class TestWPTCssColor < Minitest::Test
  def color(value, prop: "color")
    document = Dommy.parse("<style>#t { #{prop}: #{value} }</style><p id=\"t\">x</p>").document
    document.default_view.get_computed_style(document.get_element_by_id("t"))[prop]
  end

  def test_named_colors
    assert_equal "rgb(255, 0, 0)", color("red")
    assert_equal "rgb(102, 51, 153)", color("rebeccapurple")
    assert_equal "rgba(0, 0, 0, 0)", color("transparent", prop: "background-color")
  end

  def test_hex_notations
    assert_equal "rgb(170, 187, 204)", color("#abc")
    assert_equal "rgb(0, 255, 0)", color("#00ff00")
    assert_equal "rgb(255, 0, 0)", color("#ff0000")
  end

  def test_hex_with_alpha
    assert_equal "rgba(255, 0, 0, 0.4)", color("#ff000066")
  end

  def test_legacy_rgb_and_rgba
    assert_equal "rgb(1, 2, 3)", color("rgb(1, 2, 3)")
    assert_equal "rgba(0, 0, 255, 0.25)", color("rgba(0, 0, 255, 0.25)")
  end

  # css-color-4: out-of-range channels clamp.
  def test_channel_clamping
    assert_equal "rgb(255, 0, 0)", color("rgb(300, -5, 0)")
    assert_equal "rgb(255, 0, 0)", color("rgba(255, 0, 0, 5)") # alpha 5 -> 1 -> rgb
  end

  # css-color-4: percentage channels.
  def test_percentage_channels
    assert_equal "rgb(255, 0, 0)", color("rgb(100%, 0%, 0%)")
    assert_equal "rgb(128, 128, 128)", color("rgb(50%, 50%, 50%)")
  end

  # css-color-4 §16.1: modern space-separated syntax with `/` alpha.
  def test_modern_space_syntax
    assert_equal "rgb(255, 0, 0)", color("rgb(255 0 0)")
    assert_equal "rgba(255, 0, 0, 0.5)", color("rgb(255 0 0 / 50%)")
    assert_equal "rgba(255, 0, 0, 0.5)", color("rgb(100% 0% 0% / 0.5)")
  end

  # css-color-4 §7: hsl()/hsla() compute to rgb().
  def test_hsl_and_hsla
    assert_equal "rgb(255, 0, 0)", color("hsl(0, 100%, 50%)")
    assert_equal "rgb(0, 255, 0)", color("hsl(120 100% 50%)")
    assert_equal "rgb(0, 0, 255)", color("hsl(240deg 100% 50%)")
    assert_equal "rgba(255, 0, 0, 0.5)", color("hsla(0, 100%, 50%, 0.5)")
  end
end
