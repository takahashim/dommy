# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for Media Queries Level 4 evaluated through
# window.matchMedia. Adapted (not mirrored): the WPT files use testharness.js
# over matchMedia(...).matches; the same queries run against Dommy's evaluator,
# whose default media environment is 1280x720, light scheme, fine pointer, dpr 1.
#
# WPT: css/mediaqueries/*.html, cssom-view/MediaQueryList-*.html
# Spec: https://drafts.csswg.org/mediaqueries-4/
class TestWPTMediaQueries < Minitest::Test
  include DommyTestHelper

  def matches?(query, width: 1280, height: 720)
    window = make_window
    window.resize_to(width, height)
    window.__js_call__("matchMedia", [query]).matches
  end

  def test_width_features
    assert matches?("(min-width: 600px)")
    refute matches?("(min-width: 5000px)")
    assert matches?("(max-width: 2000px)")
  end

  # mediaqueries-4 §2.3: range syntax.
  def test_range_syntax
    assert matches?("(width >= 600px)")
    assert matches?("(400px <= width <= 1500px)")
    refute matches?("(width < 100px)")
  end

  def test_orientation
    assert matches?("(orientation: landscape)")
    assert matches?("(orientation: portrait)", width: 700, height: 1000)
  end

  def test_aspect_ratio
    assert matches?("(min-aspect-ratio: 1/1)")    # 1280:720 is wider than 1:1
    refute matches?("(min-aspect-ratio: 2/1)")
  end

  def test_discrete_features
    assert matches?("(prefers-color-scheme: light)")
    refute matches?("(prefers-color-scheme: dark)")
    assert matches?("(hover: hover)")
    assert matches?("(pointer: fine)")
    assert matches?("(resolution: 1dppx)")
  end

  # §3: boolean operators and the media-type prefix.
  def test_logical_operators_and_types
    assert matches?("not (min-width: 5000px)")
    assert matches?("(min-width: 100px) and (max-width: 5000px)")
    assert matches?("(min-width: 5000px), (min-width: 100px)")
    assert matches?("screen")
    refute matches?("print")
    assert matches?("only screen")
    assert matches?("") # the empty query list matches
  end

  # An unknown feature makes the query `not all` (false), never raising.
  def test_unknown_feature_is_false
    refute matches?("(grid: 1)")
    refute matches?("(totally-made-up: 5)")
  end
end
