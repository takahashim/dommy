# frozen_string_literal: true

require_relative "test_helper"

# CSS counters (CSS Lists 3 §4; css-cascade.md): counter-reset / -increment /
# -set value computation with scope + nesting, and counter()/counters()
# resolution for generated-content text. Layout/rendering stays a non-goal — the
# consumer is the accessible name — so these test the value model directly.
class TestCssCounters < Minitest::Test
  CASCADE = Dommy::Internal::CSS::Cascade
  COUNTERS = Dommy::Internal::CSS::Counters

  def values(html, id)
    doc = Dommy.parse(html).document
    CASCADE.counter_values(doc.get_element_by_id(id))
  end

  def test_increment_runs_along_siblings
    html = '<style>ol{counter-reset:item} li{counter-increment:item}</style>' \
           '<ol><li>a</li><li id="t">b</li></ol>'
    assert_equal({ "item" => [2] }, values(html, "t"))
  end

  def test_reset_creates_a_fresh_counter
    html = '<style>ol{counter-reset:item} li{counter-increment:item}</style>' \
           '<ol><li>a</li></ol><ol><li id="t">b</li></ol>'
    assert_equal({ "item" => [1] }, values(html, "t"))
  end

  def test_nested_reset_stacks_counters
    html = '<style>ol{counter-reset:item} li{counter-increment:item}</style>' \
           '<ol><li>a</li><li>b<ol><li>x</li><li id="t">y</li></ol></li></ol>'
    assert_equal({ "item" => [2, 2] }, values(html, "t"))
  end

  def test_increment_without_reset_implicitly_creates
    html = '<style>li{counter-increment:item}</style><li>a</li><li id="t">b</li>'
    assert_equal({ "item" => [2] }, values(html, "t"))
  end

  def test_reset_with_explicit_value_and_increment_amount
    html = '<style>ol{counter-reset:item 10} li{counter-increment:item 5}</style>' \
           '<ol><li id="t">a</li></ol>'
    assert_equal({ "item" => [15] }, values(html, "t"))
  end

  # ---- counter() / counters() resolution ----

  def test_counter_uses_innermost_value
    vals = { "item" => [2, 3] }
    assert_equal '"3"', COUNTERS.substitute('counter(item)', vals)
  end

  def test_counters_joins_the_stack
    vals = { "item" => [2, 3] }
    assert_equal '"2.3"', COUNTERS.substitute('counters(item, ".")', vals)
  end

  def test_counter_of_unknown_name_is_zero
    assert_equal '"0"', COUNTERS.substitute('counter(missing)', {})
  end

  def test_counter_styles
    assert_equal '"c"', COUNTERS.substitute('counter(i, lower-alpha)', { "i" => [3] })
    assert_equal '"III"', COUNTERS.substitute('counter(i, upper-roman)', { "i" => [3] })
    assert_equal '"03"', COUNTERS.substitute('counter(i, decimal-leading-zero)', { "i" => [3] })
  end
end
