# frozen_string_literal: true

require_relative "test_helper"

# WHATWG "report an exception" as the single funnel every uncaught error goes
# through: it fires a cancelable `error` event at the global, the page may
# handle it, and only an UNHANDLED report reaches the host (the browser's
# "may report the error to a developer console" step).
class TestExceptionReporting < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @btn = @win.document.get_element_by_id("b")
    @unhandled = []
    @win.__internal_on_unhandled_error__ { |err| @unhandled << err }
  end

  # --- The report's verdict ---

  def test_an_unreported_exception_reaches_the_host
    boom = RuntimeError.new("boom")
    @btn.add_event_listener("click", proc { raise boom })
    @btn.click

    assert_equal [boom], @unhandled,
      "a listener exception the page ignores reaches the host with its Ruby identity"
  end

  def test_prevent_default_marks_the_exception_handled
    @win.add_event_listener("error", proc { |e| e.__js_call__("preventDefault", []) })
    @btn.add_event_listener("click", proc { raise "boom" })
    @btn.click

    assert_empty @unhandled,
      "an error event the page cancels is handled, so the host never sees it"
  end

  def test_onerror_returning_true_marks_the_exception_handled
    @win.__js_set__("onerror", proc { |*_args| true })
    @btn.add_event_listener("click", proc { raise "boom" })
    @btn.click

    assert_empty @unhandled, "window.onerror returning true cancels the report"
  end

  def test_onerror_returning_false_leaves_the_exception_unhandled
    @win.__js_set__("onerror", proc { |*_args| false })
    @btn.add_event_listener("click", proc { raise "boom" })
    @btn.click

    assert_equal 1, @unhandled.length,
      "the special error handler cancels only on true, so false still reports"
  end

  def test_report_returns_whether_the_page_handled_it
    refute @win.__internal_report_exception__("v", "m"), "nobody handled it"

    @win.add_event_listener("error", proc { |e| e.__js_call__("preventDefault", []) })

    assert @win.__internal_report_exception__("v", "m"), "a canceling listener handled it"
  end

  # --- What the page sees ---

  def test_the_error_event_carries_the_source_position
    seen = nil
    @win.add_event_listener("error", proc { |e| seen = e })
    @win.__internal_report_exception__("v", "m", filename: "/app.js", lineno: 12, colno: 5)

    assert_equal "/app.js", seen.__js_get__("filename")
    assert_equal 12, seen.__js_get__("lineno")
    assert_equal 5, seen.__js_get__("colno")
  end

  def test_report_error_fires_the_same_error_event
    seen = nil
    @win.add_event_listener("error", proc { |e| seen = e })
    thrown = RuntimeError.new("reported")
    @win.__js_call__("reportError", [thrown])

    refute_nil seen, "self.reportError(e) IS report-an-exception exposed to authors"
    assert_same thrown, seen.__js_get__("error")
    assert_equal "reported", seen.__js_get__("message")
    assert_equal [thrown], @unhandled
  end

  def test_report_error_is_cancelable_like_any_other_report
    @win.add_event_listener("error", proc { |e| e.__js_call__("preventDefault", []) })
    @win.__js_call__("reportError", [RuntimeError.new("reported")])

    assert_empty @unhandled
  end

  # --- The entry-point boundary ---

  def test_a_throwing_listener_does_not_stop_the_remaining_listeners
    ran = []
    @btn.add_event_listener("click", proc { ran << :first; raise "boom" })
    @btn.add_event_listener("click", proc { ran << :second })
    @btn.click

    assert_equal %i[first second], ran,
      "an exception unwinds to the callback boundary, not to the whole dispatch"
    assert_equal 1, @unhandled.length
  end

  def test_each_unhandled_listener_exception_is_reported_separately
    @btn.add_event_listener("click", proc { raise "one" })
    @btn.add_event_listener("click", proc { raise "two" })
    @btn.click

    assert_equal %w[one two], @unhandled.map(&:message)
  end

  # --- Rejections ---

  def test_an_unhandled_rejection_fires_a_cancelable_event_and_reaches_the_host
    seen = nil
    @win.add_event_listener("unhandledrejection", proc { |e| seen = e })
    reason = RuntimeError.new("nope")
    @win.__internal_report_rejection__(reason)

    refute_nil seen
    assert_equal "unhandledrejection", seen.__js_get__("type")
    assert_same reason, seen.__js_get__("reason")
    assert_equal [reason], @unhandled
  end

  def test_a_canceled_rejection_never_reaches_the_host
    @win.add_event_listener("unhandledrejection", proc { |e| e.__js_call__("preventDefault", []) })
    @win.__internal_report_rejection__(RuntimeError.new("nope"))

    assert_empty @unhandled,
      "a page that handles unhandledrejection suppresses it, as in a browser"
  end

  # --- Re-entrancy ---

  def test_an_error_handler_that_throws_is_not_reported_again
    @win.add_event_listener("error", proc { raise "from the handler" })
    @btn.add_event_listener("click", proc { raise "original" })
    @btn.click

    assert_equal ["original"], @unhandled.map(&:message),
      "the guarded-out nested report is dropped rather than reaching the host"
  end
end
