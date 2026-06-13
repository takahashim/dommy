# frozen_string_literal: true

require_relative "../test_helper"
require "dommy/internal/css/supports"

# The @supports <supports-condition> evaluator. Dommy has no feature database,
# so feature queries are optimistic (a well-formed declaration is "supported");
# the value is in the boolean structure (not/and/or, grouping, selector()).
class TestCssSupports < Minitest::Test
  S = Dommy::Internal::CSS::Supports

  def test_simple_feature_query_is_supported
    assert S.match?("(display: grid)")
    assert S.match?("(color: red)")
  end

  def test_empty_or_malformed_is_false
    refute S.match?("")
    refute S.match?("(display:)")
    refute S.match?("garbage")
  end

  def test_not
    refute S.match?("not (display: grid)")
    assert S.match?("not (display:)") # not(false) => true
  end

  def test_and
    assert S.match?("(display: grid) and (color: red)")
    refute S.match?("(display: grid) and (color:)")
  end

  def test_or
    assert S.match?("(display: grid) or (color:)")
    refute S.match?("(display:) or (color:)")
  end

  def test_nested_grouping
    assert S.match?("((display: grid))")
    assert S.match?("(not (display:)) and (color: red)")
  end

  def test_selector_function
    assert S.match?("selector(a:hover)")
    assert S.match?("selector(div > .x)")
    refute S.match?("selector(##bad)")
  end

  def test_mixed_and_or_is_invalid
    refute S.match?("(a: b) and (c: d) or (e: f)")
  end

  def test_never_raises
    assert_equal false, S.match?(nil)
    assert_equal false, S.match?("((((")
  end
end
