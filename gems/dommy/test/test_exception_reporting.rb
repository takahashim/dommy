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

  # --- Where the error happened ---

  # A JS engine puts its frames on the raised exception, which is the only place
  # the position can come from once the thrown value itself has crossed as an
  # opaque handle.
  def test_the_source_position_comes_from_the_top_page_frame
    error = RuntimeError.new("boom")
    error.set_backtrace(["at inner (http://example.test/app.js:12:5)",
      "at outer (http://example.test/app.js:30:1)"])

    assert_equal ["http://example.test/app.js", 12, 5],
      Dommy::Internal::ExceptionReport.source_position(error)
  end

  def test_dommy_own_frames_are_not_reported_as_the_page_position
    error = RuntimeError.new("boom")
    error.set_backtrace(["at <anonymous> (host_runtime.js:696:54)",
      "at handler (http://example.test/app.js:3:9)"])

    assert_equal ["http://example.test/app.js", 3, 9],
      Dommy::Internal::ExceptionReport.source_position(error),
      "the page did not write the bridge's frames"
  end

  def test_a_frame_without_a_function_name_still_gives_a_position
    error = RuntimeError.new("boom")
    error.set_backtrace(["at http://example.test/app.js:7:2"])

    assert_equal ["http://example.test/app.js", 7, 2],
      Dommy::Internal::ExceptionReport.source_position(error)
  end

  def test_an_error_with_no_usable_frame_reports_no_position
    assert_equal ["", 0, 0], Dommy::Internal::ExceptionReport.source_position(RuntimeError.new("boom"))
  end

  def test_the_report_carries_the_position_to_the_page
    seen = nil
    @win.add_event_listener("error", proc { |e| seen = e })
    error = RuntimeError.new("boom")
    error.set_backtrace(["at go (http://example.test/app.js:4:11)"])
    Dommy::Internal::ExceptionReport.report_at(@win, error)

    assert_equal "http://example.test/app.js", seen.__js_get__("filename")
    assert_equal 4, seen.__js_get__("lineno")
    assert_equal 11, seen.__js_get__("colno")
  end

  # An engine names source it was handed with no name of its own `<code>`; a
  # browser reports the document's URL for an inline script.
  def test_an_anonymous_source_is_reported_as_the_document_url
    @win.location.__internal_set_url__("http://example.test/page")
    seen = nil
    @win.add_event_listener("error", proc { |e| seen = e })
    error = RuntimeError.new("boom")
    error.set_backtrace(["at go (<code>:1:9)"])
    Dommy::Internal::ExceptionReport.report_at(@win, error)

    assert_equal "http://example.test/page", seen.__js_get__("filename")
  end

  # --- Both halves of promise rejection tracking ---

  # The engine hands both halves to one entry point with the real promise, so
  # the window can pair a later "handled" with the report it takes back.
  def test_a_reported_rejection_is_retracted_when_it_is_handled
    records = []
    retracted = []
    @win.__internal_on_unhandled_error__ { |_err| records.push(records.length + 1).last }
    @win.__internal_on_rejection_handled__ { |record| retracted << record }
    promise = Dommy::Bridge::JSValue.new(7, "the promise")

    @win.__internal_handle_promise_rejection__("unhandledrejection", "reason", promise: promise)
    @win.__internal_handle_promise_rejection__("rejectionhandled", "reason", promise: promise)

    assert_equal [1], records
    assert_equal [1], retracted, "the report the page recovered from is taken back"
  end

  def test_a_handled_notice_for_something_never_reported_is_ignored
    retracted = []
    @win.__internal_on_rejection_handled__ { |record| retracted << record }
    @win.__internal_handle_promise_rejection__("rejectionhandled", "reason",
      promise: Dommy::Bridge::JSValue.new(9))

    assert_empty retracted
  end

  def test_a_rejection_the_page_cancels_is_never_recorded_to_retract
    records = []
    retracted = []
    @win.__internal_on_unhandled_error__ { |_err| records << :recorded }
    @win.__internal_on_rejection_handled__ { |record| retracted << record }
    @win.add_event_listener("unhandledrejection", proc { |e| e.__js_call__("preventDefault", []) })
    promise = Dommy::Bridge::JSValue.new(3)

    @win.__internal_handle_promise_rejection__("unhandledrejection", "reason", promise: promise)
    @win.__internal_handle_promise_rejection__("rejectionhandled", "reason", promise: promise)

    assert_empty records
    assert_empty retracted, "nothing was reported, so there is nothing to take back"
  end

  def test_rejectionhandled_reaches_the_page_and_is_not_cancelable
    seen = nil
    @win.add_event_listener("rejectionhandled", proc { |e| seen = e })
    promise = Dommy::Bridge::JSValue.new(5)
    @win.__internal_handle_promise_rejection__("unhandledrejection", "why", promise: promise)
    @win.__internal_handle_promise_rejection__("rejectionhandled", "why", promise: promise)

    refute_nil seen
    assert_same promise, seen.__js_get__("promise")
    assert_equal "why", seen.__js_get__("reason")
    refute seen.__js_get__("cancelable"), "the page is being informed, not consulted"
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
