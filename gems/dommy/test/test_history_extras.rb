# frozen_string_literal: true

require_relative "test_helper"

class TestHistoryExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @hist = @win.__js_get__("history")
  end

  def test_scroll_restoration_default_auto
    assert_equal("auto", @hist.__js_get__("scrollRestoration"))
  end

  def test_scroll_restoration_manual
    @hist.__js_set__("scrollRestoration", "manual")
    assert_equal("manual", @hist.__js_get__("scrollRestoration"))
  end

  def test_scroll_restoration_invalid_value_ignored
    @hist.__js_set__("scrollRestoration", "manual")
    @hist.__js_set__("scrollRestoration", "bogus")
    assert_equal("manual", @hist.__js_get__("scrollRestoration"))
  end

  def test_go_zero_is_noop
    # `go(0)` would reload in a real browser; here it just doesn't crash.
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    @hist.__js_call__("go", [0])
    assert_equal({"n" => 1}, @hist.__js_get__("state"))
  end

  def test_go_out_of_bounds_is_silent
    @hist.__js_call__("go", [100])
    @hist.__js_call__("go", [-100])
    # Doesn't crash.
    assert(true)
  end
end
