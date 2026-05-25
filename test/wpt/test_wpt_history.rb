# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for History session-stack semantics not covered
# by test/test_history_full.rb (which exercises basic push/replace/
# back/forward/go) or test_history_extras.rb (scrollRestoration,
# go(0), out-of-bounds go).
#
# WPT: html/browsers/history/the-history-interface/history_pushstate.html,
#      html/browsers/history/the-history-interface/history_state_clone.html
# Spec: https://html.spec.whatwg.org/multipage/history.html#the-history-interface

class TestWPTHistoryBoundaries < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @hist = @win.__js_get__("history")
  end

  def test_back_on_single_entry_is_noop
    # The initial entry is at cursor 0; back() should leave the
    # cursor there with no state change. The default state is nil.
    initial_length = @hist.__js_get__("length")
    @hist.__js_call__("back", [])
    assert_nil(@hist.__js_get__("state"))
    assert_equal(initial_length, @hist.__js_get__("length"))
  end

  def test_forward_on_top_entry_is_noop
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    # At the top of the stack; forward() should do nothing.
    state_before = @hist.__js_get__("state")
    @hist.__js_call__("forward", [])
    assert_equal(state_before, @hist.__js_get__("state"))
  end
end

class TestWPTHistoryStackTruncation < Minitest::Test
  # Spec: pushState after a back() discards entries beyond the
  # current cursor. After truncation, forward() can no longer reach
  # the dropped entries.

  include DommyTestHelper

  def setup
    @win = make_window
    @hist = @win.__js_get__("history")
    @hist.__js_call__("pushState", [{"n" => 1}, "", "/a"])
    @hist.__js_call__("pushState", [{"n" => 2}, "", "/b"])
    @hist.__js_call__("pushState", [{"n" => 3}, "", "/c"])
  end

  def test_pushstate_after_back_truncates_forward_entries
    @hist.__js_call__("back", []) # cursor at /b
    @hist.__js_call__("back", []) # cursor at /a
    @hist.__js_call__("pushState", [{"n" => 4}, "", "/d"])
    # /b and /c are dropped; total length is initial(1) + /a + /d = 3.
    assert_equal(3, @hist.__js_get__("length"))
  end

  def test_forward_cannot_recover_truncated_entry
    @hist.__js_call__("back", [])
    @hist.__js_call__("back", [])
    @hist.__js_call__("pushState", [{"n" => 4}, "", "/d"])
    @hist.__js_call__("forward", [])
    # forward() finds nothing past /d; state should still be /d.
    assert_equal({"n" => 4}, @hist.__js_get__("state"))
  end
end

class TestWPTHistoryStateStorage < Minitest::Test
  # Dommy deviation: WHATWG specifies that pushState/replaceState
  # store a structured clone of the supplied state object, so
  # external mutation of the original cannot affect history.state.
  # Dommy holds the original reference, so mutating the caller's
  # hash mutates history.state too. This test documents the current
  # behaviour rather than the spec; a future structured_clone()
  # hook in pushState/replaceState would flip this assertion.

  include DommyTestHelper

  def setup
    @win = make_window
    @hist = @win.__js_get__("history")
  end

  def test_pushstate_state_is_held_by_reference_not_cloned
    state = {"count" => 1}
    @hist.__js_call__("pushState", [state, "", "/a"])
    state["count"] = 999
    # Spec would say "count" => 1 (structured clone at push time).
    # Dommy reflects the mutation.
    assert_equal(999, @hist.__js_get__("state")["count"])
  end

  def test_replacestate_state_is_held_by_reference_not_cloned
    state = {"value" => "old"}
    @hist.__js_call__("replaceState", [state, "", "/r"])
    state["value"] = "new"
    assert_equal("new", @hist.__js_get__("state")["value"])
  end
end
