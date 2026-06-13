# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for CSS Values & Units: calc()/min()/max()/clamp()
# evaluation in computed values. Adapted (not mirrored): the WPT files assert
# getComputedStyle of properties set to math functions. Dommy has no layout,
# so a function resolves only when every term reduces to a length or number;
# a percentage (containing-block dependent) keeps the function symbolic, which
# is what browsers' computed value also does.
#
# WPT: css/css-values/calc-*.html, css/css-values/minmax-*.html,
#      css/css-values/clamp-*.html
# Spec: https://drafts.csswg.org/css-values-4/#calc-func,
#       https://drafts.csswg.org/css-values-4/#comp-func
class TestWPTCssValues < Minitest::Test
  def value(decls, prop)
    document = Dommy.parse("<style>#t { #{decls} }</style><p id=\"t\">x</p>").document
    document.default_view.get_computed_style(document.get_element_by_id("t"))[prop]
  end

  # css-values-4 §10.1: calc() with absolute terms reduces to a single value.
  def test_calc_addition_and_subtraction
    assert_equal "12px", value("letter-spacing: calc(10px + 2px)", "letter-spacing")
    assert_equal "8px", value("letter-spacing: calc(10px - 2px)", "letter-spacing")
  end

  def test_calc_multiplication_and_division
    assert_equal "20px", value("letter-spacing: calc(10px * 2)", "letter-spacing")
    assert_equal "5px", value("letter-spacing: calc(10px / 2)", "letter-spacing")
  end

  # css-values-4 §10.3: * and / bind tighter than + and -.
  def test_calc_operator_precedence_and_parentheses
    assert_equal "14px", value("letter-spacing: calc(10px + 2px * 2)", "letter-spacing")
    assert_equal "24px", value("letter-spacing: calc((10px + 2px) * 2)", "letter-spacing")
  end

  def test_calc_mixes_font_relative_and_viewport_terms
    assert_equal "28px", value("font-size: 16px; letter-spacing: calc(2rem - 4px)", "letter-spacing")
    assert_equal "630px", value("letter-spacing: calc(50vw - 10px)", "letter-spacing") # 1280/2 - 10
  end

  def test_nested_calc
    assert_equal "24px", value("letter-spacing: calc(calc(10px + 2px) * 2)", "letter-spacing")
  end

  # css-values-4 §10.2: min()/max()/clamp().
  def test_min_max
    assert_equal "10px", value("letter-spacing: min(10px, 20px)", "letter-spacing")
    assert_equal "20px", value("letter-spacing: max(10px, 20px)", "letter-spacing")
  end

  def test_clamp_picks_the_middle_value
    assert_equal "15px", value("letter-spacing: clamp(10px, 15px, 20px)", "letter-spacing")
    assert_equal "20px", value("letter-spacing: clamp(10px, 50px, 20px)", "letter-spacing")
    assert_equal "10px", value("letter-spacing: clamp(10px, 5px, 20px)", "letter-spacing")
  end

  def test_clamp_with_viewport_for_font_size
    assert_equal "20px", value("font-size: clamp(12px, 50vw, 20px)", "font-size")
  end

  # A percentage term is containing-block dependent (layout): the function
  # stays symbolic, matching the browser computed value.
  def test_percentage_term_keeps_calc_symbolic
    assert_equal "calc(100% - 10px)", value("letter-spacing: calc(100% - 10px)", "letter-spacing")
  end

  # Invalid unit algebra (length+number, length*length, /length) does not
  # reduce — the specified value is kept.
  def test_invalid_unit_algebra_is_not_reduced
    assert_equal "calc(10px + 2)", value("letter-spacing: calc(10px + 2)", "letter-spacing")
    assert_equal "calc(10px * 2px)", value("letter-spacing: calc(10px * 2px)", "letter-spacing")
  end
end
