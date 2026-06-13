# frozen_string_literal: true

require_relative "test_helper"
require "dommy/internal/css/color"

class TestCssColor < Minitest::Test
  Color = Dommy::Internal::CSS::Color

  def test_named_colors
    assert_equal "rgb(255, 0, 0)", Color.normalize("red")
    assert_equal "rgb(102, 51, 153)", Color.normalize("rebeccapurple")
    assert_equal "rgb(128, 128, 128)", Color.normalize("grey")
    assert_equal "rgb(128, 128, 128)", Color.normalize("gray")
  end

  def test_named_color_table_has_all_148_keywords
    assert_equal 148, Color::NAMED.size
  end

  def test_case_insensitive_and_whitespace
    assert_equal "rgb(255, 0, 0)", Color.normalize("Red")
    assert_equal "rgb(0, 0, 255)", Color.normalize("  BLUE  ")
    assert_equal "rgb(0, 255, 0)", Color.normalize("#0F0")
  end

  def test_transparent
    assert_equal "rgba(0, 0, 0, 0)", Color.normalize("transparent")
    assert_equal "rgba(0, 0, 0, 0)", Color.normalize("Transparent")
  end

  def test_hex_3_digits
    assert_equal "rgb(255, 0, 0)", Color.normalize("#f00")
    assert_equal "rgb(0, 255, 0)", Color.normalize("#0f0")
  end

  def test_hex_6_digits
    assert_equal "rgb(102, 51, 153)", Color.normalize("#663399")
    assert_equal "rgb(255, 255, 255)", Color.normalize("#FFFFFF")
  end

  def test_hex_4_digits
    # #f008 => alpha 0x88 / 255
    assert_equal "rgba(255, 0, 0, 0.53333)", Color.normalize("#f008")
    # full alpha collapses to rgb()
    assert_equal "rgb(255, 0, 0)", Color.normalize("#f00f")
  end

  def test_hex_8_digits
    # 0x80 / 255 = 0.50196 (rounded to 5 decimals)
    assert_equal "rgba(255, 0, 0, 0.50196)", Color.normalize("#ff000080")
    assert_equal "rgb(255, 0, 0)", Color.normalize("#ff0000ff")
    assert_equal "rgba(0, 0, 255, 0)", Color.normalize("#0000ff00")
  end

  def test_rgb_spacing_normalization
    assert_equal "rgb(1, 2, 3)", Color.normalize("rgb(1,2,3)")
    assert_equal "rgb(1, 2, 3)", Color.normalize("rgb( 1 , 2 , 3 )")
    assert_equal "rgb(1, 2, 3)", Color.normalize("RGB(1, 2, 3)")
  end

  def test_rgba_collapses_when_alpha_is_one
    assert_equal "rgb(1, 2, 3)", Color.normalize("rgba(1, 2, 3, 1)")
    assert_equal "rgb(1, 2, 3)", Color.normalize("rgba(1,2,3,1.0)")
  end

  def test_rgba_keeps_fractional_alpha
    assert_equal "rgba(1, 2, 3, 0.5)", Color.normalize("rgba(1, 2, 3, 0.5)")
    assert_equal "rgba(1, 2, 3, 0.5)", Color.normalize("rgba(1,2,3,.5)")
    assert_equal "rgba(1, 2, 3, 0)", Color.normalize("rgba(1, 2, 3, 0)")
  end

  def test_normalize_clamps_rgb_components
    assert_equal "rgb(255, 0, 0)", Color.normalize("rgb(300, 0, 0)")
    assert_equal "rgb(0, 255, 0)", Color.normalize("rgb(-10, 999, -1)")
  end

  def test_normalize_clamps_alpha
    # alpha > 1 clamps to 1, which collapses to rgb()
    assert_equal "rgb(0, 0, 0)", Color.normalize("rgba(0, 0, 0, 5)")
    assert_equal "rgba(0, 0, 0, 0)", Color.normalize("rgba(0, 0, 0, -0.5)")
  end

  def test_extract_named_and_hex
    assert_equal "rgb(255, 0, 0)", Color.extract("red url(x.png)")
    assert_equal "rgb(170, 187, 204)", Color.extract("url(x.png) #abc no-repeat")
    assert_equal "rgba(0, 0, 0, 0)", Color.extract("transparent url(x.png)")
  end

  def test_extract_rgb_function
    assert_equal "rgb(1, 2, 3)", Color.extract("url(x.png) rgb(1, 2, 3)")
    assert_equal "rgba(1, 2, 3, 0.5)", Color.extract("rgba(1, 2, 3, 0.5) no-repeat")
  end

  def test_extract_ignores_hex_inside_url
    assert_nil Color.extract("url(#abc)")
    assert_nil Color.extract("no-repeat url(#abc) center")
  end

  def test_extract_ignores_colors_inside_gradients
    assert_nil Color.extract("linear-gradient(to right, red 0%, blue 100%)")
    assert_nil Color.extract("linear-gradient(red, blue)")
    assert_nil Color.extract("linear-gradient(rgb(1, 2, 3), blue)")
  end

  def test_extract_top_level_color_next_to_gradient
    assert_equal "rgb(255, 0, 0)", Color.extract("linear-gradient(blue, green) red")
  end

  def test_extract_no_color
    assert_nil Color.extract("url(x.png) no-repeat center")
  end

  def test_hsl_normalizes_to_rgb
    assert_equal "rgb(64, 191, 64)", Color.normalize("hsl(120, 50%, 50%)")
    assert_equal "rgb(255, 0, 0)", Color.normalize("hsl(0 100% 50%)")
    assert_equal "rgba(0, 0, 255, 0.5)", Color.normalize("hsla(240, 100%, 50%, 0.5)")
  end

  def test_modern_and_percentage_rgb
    assert_equal "rgba(255, 0, 0, 0.5)", Color.normalize("rgb(255 0 0 / 50%)")
    assert_equal "rgb(255, 0, 0)", Color.normalize("rgb(100%, 0%, 0%)")
  end

  def test_unknown_values_pass_through
    assert_equal "var(--main-color)", Color.normalize("var(--main-color)")
    assert_equal "currentcolor", Color.normalize("currentcolor")
    assert_equal "not-a-color", Color.normalize("not-a-color")
  end
end
