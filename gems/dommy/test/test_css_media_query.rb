# frozen_string_literal: true

require_relative "test_helper"
require "dommy/internal/css/media_query"

class TestCssMediaQuery < Minitest::Test
  MQ = Dommy::Internal::CSS::MediaQuery

  # Explicit environment per test; defaults mirror Environment.default
  # (1280x720, dpr 1.0, light, no-preference, hover, fine).
  def env(viewport_width: 1280, viewport_height: 720, device_pixel_ratio: 1.0,
          prefers_color_scheme: "light", prefers_reduced_motion: "no-preference",
          hover: "hover", pointer: "fine")
    MQ::Environment.new(
      viewport_width: viewport_width, viewport_height: viewport_height,
      device_pixel_ratio: device_pixel_ratio,
      prefers_color_scheme: prefers_color_scheme,
      prefers_reduced_motion: prefers_reduced_motion,
      hover: hover, pointer: pointer
    )
  end

  # --- width / height -------------------------------------------------

  def test_min_width
    assert MQ.match?("(min-width: 600px)", env(viewport_width: 800))
    refute MQ.match?("(min-width: 900px)", env(viewport_width: 800))
  end

  def test_max_width
    assert MQ.match?("(max-width: 900px)", env(viewport_width: 800))
    refute MQ.match?("(max-width: 700px)", env(viewport_width: 800))
  end

  def test_width_boundary_exactly_600px
    e = env(viewport_width: 600)
    assert MQ.match?("(min-width: 600px)", e)
    assert MQ.match?("(max-width: 600px)", e)
    assert MQ.match?("(width: 600px)", e)
    refute MQ.match?("(width: 601px)", e)
  end

  def test_height
    e = env(viewport_height: 500)
    assert MQ.match?("(min-height: 500px)", e)
    refute MQ.match?("(min-height: 501px)", e)
    assert MQ.match?("(max-height: 500px)", e)
    assert MQ.match?("(height: 500px)", e)
  end

  def test_unitless_zero_is_a_valid_length
    e = env(viewport_width: 800)
    assert MQ.match?("(min-width: 0)", e)
    assert MQ.match?("(min-height: 0)", e)
    assert MQ.match?("(0 <= width)", e)
  end

  def test_unitless_nonzero_is_invalid
    e = env(viewport_width: 800)
    refute MQ.match?("(min-width: 600)", e)
    refute MQ.match?("(600 <= width)", e)
  end

  def test_em_units_are_16px
    assert MQ.match?("(min-width: 40em)", env(viewport_width: 640))
    refute MQ.match?("(min-width: 40em)", env(viewport_width: 639))
    assert MQ.match?("(min-width: 40rem)", env(viewport_width: 640))
  end

  def test_default_environment_is_1280_by_720
    assert MQ.match?("(min-width: 1280px)", MQ::DEFAULT)
    refute MQ.match?("(min-width: 1281px)", MQ::DEFAULT)
    assert MQ.match?("(max-height: 720px)", MQ::DEFAULT)
  end

  # --- range syntax -----------------------------------------------------

  def test_range_single_feature_first
    e = env(viewport_width: 700)
    assert MQ.match?("(width >= 600px)", e)
    refute MQ.match?("(width <= 600px)", e)
    assert MQ.match?("(width = 700px)", e)
  end

  def test_range_single_value_first
    e = env(viewport_width: 700)
    assert MQ.match?("(600px <= width)", e)
    refute MQ.match?("(600px >= width)", e)
    assert MQ.match?("(800px >= width)", e)
  end

  def test_range_double
    assert MQ.match?("(400px <= width <= 800px)", env(viewport_width: 700))
    refute MQ.match?("(400px <= width <= 800px)", env(viewport_width: 900))
    refute MQ.match?("(400px <= width <= 800px)", env(viewport_width: 300))
  end

  def test_range_strict_versus_inclusive
    e = env(viewport_width: 800)
    refute MQ.match?("(width < 800px)", e)
    assert MQ.match?("(width <= 800px)", e)
    refute MQ.match?("(width > 800px)", e)
    assert MQ.match?("(width >= 800px)", e)
  end

  def test_range_height
    e = env(viewport_height: 500)
    assert MQ.match?("(height >= 500px)", e)
    refute MQ.match?("(height > 500px)", e)
  end

  # --- combinators ------------------------------------------------------

  def test_comma_is_or
    e = env(viewport_width: 1280)
    assert MQ.match?("(min-width: 2000px), (min-width: 100px)", e)
    refute MQ.match?("(min-width: 2000px), (min-width: 1500px)", e)
  end

  def test_and_chain
    e = env(viewport_width: 1280, viewport_height: 720)
    assert MQ.match?("screen and (min-width: 600px) and (max-width: 1400px)", e)
    refute MQ.match?("screen and (min-width: 600px) and (orientation: portrait)", e)
  end

  def test_not_query
    e = env(viewport_width: 1280)
    assert MQ.match?("not screen and (min-width: 2000px)", e)
    refute MQ.match?("not screen and (min-width: 600px)", e)
    refute MQ.match?("not all", e)
  end

  def test_not_before_single_condition
    e = env(hover: "hover")
    refute MQ.match?("screen and not (hover)", e)
    assert MQ.match?("screen and not (hover: none)", e)
  end

  def test_only_screen
    assert MQ.match?("only screen and (min-width: 600px)", env(viewport_width: 800))
    refute MQ.match?("only print and (min-width: 600px)", env(viewport_width: 800))
  end

  def test_only_before_condition_is_invalid
    e = env(viewport_width: 800)
    refute MQ.match?("only (min-width: 0px)", e)
    refute MQ.match?("only (min-width: 600px) and (max-width: 900px)", e)
  end

  # --- media types ------------------------------------------------------

  def test_media_types
    e = env
    assert MQ.match?("screen", e)
    assert MQ.match?("all", e)
    refute MQ.match?("print", e)
    refute MQ.match?("speech", e)
    assert MQ.match?("not print", e)
  end

  # --- orientation ------------------------------------------------------

  def test_orientation
    landscape = env(viewport_width: 1280, viewport_height: 720)
    assert MQ.match?("(orientation: landscape)", landscape)
    refute MQ.match?("(orientation: portrait)", landscape)

    portrait = env(viewport_width: 600, viewport_height: 800)
    assert MQ.match?("(orientation: portrait)", portrait)
    refute MQ.match?("(orientation: landscape)", portrait)
  end

  def test_orientation_square_is_portrait
    square = env(viewport_width: 500, viewport_height: 500)
    assert MQ.match?("(orientation: portrait)", square)
    refute MQ.match?("(orientation: landscape)", square)
  end

  # --- aspect-ratio -----------------------------------------------------

  def test_aspect_ratio_exact
    e = env(viewport_width: 1280, viewport_height: 720) # exactly 16/9
    assert MQ.match?("(aspect-ratio: 16/9)", e)
    refute MQ.match?("(aspect-ratio: 4/3)", e)
  end

  def test_aspect_ratio_min_max
    e = env(viewport_width: 1280, viewport_height: 720)
    assert MQ.match?("(min-aspect-ratio: 16/9)", e)
    assert MQ.match?("(max-aspect-ratio: 16/9)", e)
    refute MQ.match?("(min-aspect-ratio: 2/1)", e)
    assert MQ.match?("(min-aspect-ratio: 4/3)", e)
    refute MQ.match?("(max-aspect-ratio: 4/3)", e)
  end

  # --- preference features ----------------------------------------------

  def test_prefers_color_scheme
    assert MQ.match?("(prefers-color-scheme: light)", env(prefers_color_scheme: "light"))
    refute MQ.match?("(prefers-color-scheme: dark)", env(prefers_color_scheme: "light"))
    assert MQ.match?("(prefers-color-scheme: dark)", env(prefers_color_scheme: "dark"))
  end

  def test_prefers_reduced_motion
    refute MQ.match?("(prefers-reduced-motion: reduce)", env(prefers_reduced_motion: "no-preference"))
    assert MQ.match?("(prefers-reduced-motion: reduce)", env(prefers_reduced_motion: "reduce"))
    assert MQ.match?("(prefers-reduced-motion: no-preference)", env(prefers_reduced_motion: "no-preference"))
  end

  # --- hover / pointer ----------------------------------------------------

  def test_hover_values
    assert MQ.match?("(hover: hover)", env(hover: "hover"))
    refute MQ.match?("(hover: none)", env(hover: "hover"))
    assert MQ.match?("(hover: none)", env(hover: "none"))
    assert MQ.match?("(any-hover: hover)", env(hover: "hover"))
  end

  def test_hover_boolean_context
    assert MQ.match?("(hover)", env(hover: "hover"))
    refute MQ.match?("(hover)", env(hover: "none"))
  end

  def test_pointer_values
    assert MQ.match?("(pointer: fine)", env(pointer: "fine"))
    refute MQ.match?("(pointer: coarse)", env(pointer: "fine"))
    assert MQ.match?("(pointer: coarse)", env(pointer: "coarse"))
    assert MQ.match?("(any-pointer: fine)", env(pointer: "fine"))
  end

  def test_pointer_boolean_context
    assert MQ.match?("(pointer)", env(pointer: "fine"))
    refute MQ.match?("(pointer)", env(pointer: "none"))
  end

  def test_width_height_boolean_context
    assert MQ.match?("(width)", env(viewport_width: 1280))
    refute MQ.match?("(width)", env(viewport_width: 0))
    assert MQ.match?("(height)", env(viewport_height: 720))
    refute MQ.match?("(height)", env(viewport_height: 0))
  end

  # --- resolution ---------------------------------------------------------

  def test_resolution
    one_x = env(device_pixel_ratio: 1.0)
    assert MQ.match?("(resolution: 1x)", one_x)
    refute MQ.match?("(resolution: 2x)", one_x)
    refute MQ.match?("(min-resolution: 2x)", one_x)
    assert MQ.match?("(max-resolution: 1x)", one_x)

    two_x = env(device_pixel_ratio: 2.0)
    assert MQ.match?("(min-resolution: 2x)", two_x)
    assert MQ.match?("(resolution: 2dppx)", two_x)
    assert MQ.match?("(min-resolution: 192dpi)", two_x)
    refute MQ.match?("(min-resolution: 192dpi)", one_x)
  end

  # --- degenerate / unparseable queries ------------------------------------

  def test_unknown_feature_is_false
    e = env
    refute MQ.match?("(monochrome)", e)
    refute MQ.match?("(min-monochrome: 1)", e)
    refute MQ.match?("(foo: bar)", e)
    refute MQ.match?("not (unknown-feature)", e) # unparseable beats negation
  end

  def test_uninterpretable_value_is_false
    e = env
    refute MQ.match?("(min-width: banana)", e)
    refute MQ.match?("(orientation: diagonal)", e)
    refute MQ.match?("(prefers-color-scheme: sepia)", e)
  end

  def test_or_combinator_is_unsupported_and_false
    e = env(viewport_width: 1280)
    refute MQ.match?("(min-width: 100px) or (min-width: 200px)", e)
    refute MQ.match?("screen or print", e)
  end

  def test_empty_string_matches
    assert MQ.match?("", env)
    assert MQ.match?("   ", env)
  end

  def test_all_matches
    assert MQ.match?("all", env)
  end

  def test_case_insensitive
    assert MQ.match?("ONLY Screen AND (MIN-WIDTH: 600PX)", env(viewport_width: 800))
    assert MQ.match?("NOT PRINT", env)
  end

  def test_default_is_frozen
    assert MQ::DEFAULT.frozen?
  end
end
