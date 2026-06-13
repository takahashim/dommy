# frozen_string_literal: true

require_relative "../test_helper"
require "dommy/internal/css/property_registry"

# calc()/min()/max()/clamp() evaluation. Resolves to px (or a number) only when
# every term reduces without layout; a % or unknown unit leaves it nil so the
# caller keeps the specified value.
class TestCssCalc < Minitest::Test
  R = Dommy::Internal::CSS::PropertyRegistry

  # 16px font, 16px root, 1000x500 viewport.
  def calc(expr)
    R.evaluate_calc(expr, font_size: 16.0, root_font_size: 16.0,
                          viewport_width: 1000, viewport_height: 500)
  end

  def test_absolute_arithmetic
    assert_equal "12px", calc("calc(10px + 2px)")
    assert_equal "8px", calc("calc(10px - 2px)")
    assert_equal "20px", calc("calc(10px * 2)")
    assert_equal "5px", calc("calc(10px / 2)")
  end

  def test_font_relative_and_viewport_terms
    assert_equal "28px", calc("calc(2rem - 4px)")   # 32 - 4
    assert_equal "90px", calc("calc(10vw - 10px)")  # 100 - 10
    assert_equal "32px", calc("calc(2em)")          # 2 * 16
  end

  def test_precedence_and_nesting
    assert_equal "14px", calc("calc(10px + 2px * 2)")
    assert_equal "24px", calc("calc((10px + 2px) * 2)")
    assert_equal "24px", calc("calc(calc(10px + 2px) * 2)")
  end

  def test_unitless_number_result
    assert_equal "1.5", calc("calc(1 + 0.5)")
    assert_equal "3", calc("calc(6 / 2)")
  end

  def test_min_max_clamp
    assert_equal "10px", calc("min(10px, 20px)")
    assert_equal "20px", calc("max(10px, 20px)")
    assert_equal "15px", calc("clamp(10px, 15px, 20px)")
    assert_equal "20px", calc("clamp(10px, 50px, 20px)") # clamped to max
    assert_equal "10px", calc("clamp(10px, 5px, 20px)")  # clamped to min
  end

  def test_percentage_is_left_unresolved
    assert_nil calc("calc(100% - 10px)")
    assert_nil calc("calc(50%)")
  end

  def test_unit_clashes_are_unresolved
    assert_nil calc("calc(10px + 2)")     # length + number
    assert_nil calc("calc(10px * 2px)")   # length * length
    assert_nil calc("calc(10px / 2px)")   # divide by length
    assert_nil calc("min(10px, 5)")       # mixed kinds
  end

  def test_unknown_units_and_garbage_are_unresolved
    assert_nil calc("calc(10ch + 2px)")
    assert_nil calc("calc(red)")
    assert_nil calc("calc(10px +)")
  end

  def test_non_calc_values_return_nil
    assert_nil calc("12px")
    assert_nil calc("red")
  end
end
