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

  def test_unknown_values_pass_through
    assert_equal "hsl(120, 50%, 50%)", Color.normalize("hsl(120, 50%, 50%)")
    assert_equal "var(--main-color)", Color.normalize("var(--main-color)")
    assert_equal "currentcolor", Color.normalize("currentcolor")
    assert_equal "not-a-color", Color.normalize("not-a-color")
  end
end
