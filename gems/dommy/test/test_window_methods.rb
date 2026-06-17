# frozen_string_literal: true

require_relative "test_helper"

# Window methods frameworks reach for: dialogs (no-op headless), getSelection,
# postMessage. Regression: these had no real impl, so aliasing them as bare
# globals recursed into a stack overflow.
class TestWindowMethods < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_dialogs_are_safe_headless_noops
    assert_nil @win.__js_call__("alert", ["hi"])
    assert_equal false, @win.__js_call__("confirm", ["ok?"])
    assert_nil @win.__js_call__("prompt", ["name?"])
    assert_nil @win.__js_call__("open", ["https://example.test"])
    assert_nil @win.__js_call__("reportError", [StandardError.new("boom")])
  end

  def test_get_selection_delegates_to_the_document
    selection = @win.__js_call__("getSelection", [])
    refute_nil selection
    assert_same @win.document.get_selection, selection
  end

  def test_post_message_returns_nil_and_does_not_recurse
    # The real delivery (async message event) is covered against the JS runtime;
    # here we just assert it is a safe, non-recursing call.
    assert_nil @win.__js_call__("postMessage", ["payload"])
  end
end
