# frozen_string_literal: true

require_relative "test_helper"

# Round out History coverage to match happy-dom's full set of state /
# navigation tests.
class TestHistoryFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @hist = @win.__js_get__("history")
  end

  def test_length_starts_at_one
    assert_equal(1, @hist.__js_get__("length"))
  end

  def test_state_default_nil
    assert_nil(@hist.__js_get__("state"))
  end

  def test_state_after_push
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    assert_equal({"n" => 1}, @hist.__js_get__("state"))
  end

  def test_state_after_replace
    @hist.__js_call__("replaceState", [{"n" => 9}, "", "/x"])
    assert_equal({"n" => 9}, @hist.__js_get__("state"))
  end

  def test_length_grows_with_push_state
    before = @hist.__js_get__("length")
    @hist.__js_call__("pushState", [{}, "", "/p1"])
    @hist.__js_call__("pushState", [{}, "", "/p2"])
    assert_equal(before + 2, @hist.__js_get__("length"))
  end

  def test_replace_state_does_not_grow_length
    before = @hist.__js_get__("length")
    @hist.__js_call__("replaceState", [{}, "", "/x"])
    assert_equal(before, @hist.__js_get__("length"))
  end

  def test_back_returns_to_previous_state
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    @hist.__js_call__("pushState", [{"n" => 2}, "", "/b"])
    @hist.__js_call__("back", [])
    assert_equal({"n" => 1}, @hist.__js_get__("state"))
  end

  def test_forward_moves_back_to_later_state
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    @hist.__js_call__("pushState", [{"n" => 2}, "", "/b"])
    @hist.__js_call__("back", [])
    @hist.__js_call__("forward", [])
    assert_equal({"n" => 2}, @hist.__js_get__("state"))
  end

  def test_go_positive_delta_navigates_forward
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    @hist.__js_call__("pushState", [{"n" => 2}, "", "/b"])
    @hist.__js_call__("back", [])
    @hist.__js_call__("back", [])
    @hist.__js_call__("go", [2])
    assert_equal({"n" => 2}, @hist.__js_get__("state"))
  end

  def test_pushstate_updates_location
    @hist.__js_call__("pushState", [{}, "", "/new-path"])
    assert_equal("/new-path", @win.location.__js_get__("pathname"))
  end

  def test_replacestate_updates_location
    @hist.__js_call__("replaceState", [{}, "", "/replaced"])
    assert_equal("/replaced", @win.location.__js_get__("pathname"))
  end

  def test_back_fires_popstate_with_state
    seen = nil
    @win.add_event_listener("popstate") { |e| seen = e.__js_get__("detail") }
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    @hist.__js_call__("pushState", [{"n" => 2}, "", "/b"])
    @hist.__js_call__("back", [])
    assert_equal({"n" => 1}, seen)
  end
end
