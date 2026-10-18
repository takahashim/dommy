# frozen_string_literal: true

require_relative "test_helper"

# fetch() follows its AbortSignal (`init.signal`, or a Request's) for a
# response from the `__fetch_handler__` seam — the app dommy-rack routes to —
# as well as from a stub: an abort before the response arrives rejects the
# fetch with the signal's reason, and one after it errors the unread body.
class TestFetchAbort < Minitest::Test
  include DommyTestHelper

  class CountingHandler
    attr_reader :count

    def initialize = @count = 0

    def call(url, _init)
      @count += 1
      {"status" => 200, "body" => "from #{url}"}
    end
  end

  def setup
    @win = make_window
    @handler = CountingHandler.new
    @win.globals["__fetch_handler__"] = @handler
  end

  def fetch(*args) = Dommy::FetchFn.new(@win).__js_call__("fetch", args)

  # The promise's outcome once the work that is ready has run.
  def outcome(promise)
    result = nil
    promise.__internal_subscribe__(->(value) { result = [:fulfilled, value] }, ->(reason) { result = [:rejected, reason] })
    @win.scheduler.advance_time(0)
    result
  end

  def test_an_aborted_signal_rejects_with_its_reason_without_a_request
    controller = Dommy::AbortController.new
    controller.__js_call__("abort", ["stale"])

    assert_equal([:rejected, "stale"], outcome(fetch("/search", {"signal" => controller.signal})))
    assert_equal(0, @handler.count)
  end

  def test_an_abort_before_the_response_arrives_rejects_with_its_reason
    controller = Dommy::AbortController.new
    promise = fetch("/search", {"signal" => controller.signal})
    controller.__js_call__("abort", [])

    state, reason = outcome(promise)
    assert_equal(:rejected, state)
    assert_equal("AbortError", reason.name)
    assert_equal(1, @handler.count)
  end

  def test_a_requests_signal_is_followed
    controller = Dommy::AbortController.new
    request = Dommy::Request.new("/search", {"signal" => controller.signal}, @win)
    promise = fetch(request)
    controller.__js_call__("abort", ["stale"])

    assert_equal([:rejected, "stale"], outcome(promise))
  end

  def test_an_abort_after_the_response_errors_its_unread_body
    controller = Dommy::AbortController.new
    state, response = outcome(fetch("/search", {"signal" => controller.signal}))
    assert_equal(:fulfilled, state)
    controller.__js_call__("abort", ["stale"])

    assert_equal([:rejected, "stale"], outcome(response.__js_call__("text", [])))
  end

  def test_an_abort_errors_the_body_stream
    controller = Dommy::AbortController.new
    _, response = outcome(fetch("/search", {"signal" => controller.signal}))
    reader = response.__js_get__("body").__js_call__("getReader", [])
    controller.__js_call__("abort", ["stale"])

    assert_equal([:rejected, "stale"], outcome(reader.__js_call__("read", [])))
  end

  # An empty body is closed as soon as it arrives, so there is nothing for an
  # abort to error: Fetch errors only a body that is still readable.
  def test_an_abort_leaves_an_empty_body_closed
    @win.globals["__fetch_handler__"] = ->(_url, _init) { {"status" => 200, "body" => ""} }
    controller = Dommy::AbortController.new
    _, streamed = outcome(fetch("/empty", {"signal" => controller.signal}))
    _, consumed = outcome(fetch("/empty", {"signal" => controller.signal}))
    controller.__js_call__("abort", ["stale"])

    state, result = outcome(streamed.__js_get__("body").__js_call__("getReader", []).__js_call__("read", []))
    assert_equal(:fulfilled, state)
    assert_equal(true, result["done"])
    assert_equal([:fulfilled, ""], outcome(consumed.__js_call__("text", [])))
  end

  def test_an_abort_leaves_a_body_read_to_its_end
    controller = Dommy::AbortController.new
    _, response = outcome(fetch("/search", {"signal" => controller.signal}))
    reader = response.__js_get__("body").__js_call__("getReader", [])
    outcome(reader.__js_call__("read", []))
    controller.__js_call__("abort", ["stale"])

    state, result = outcome(reader.__js_call__("read", []))
    assert_equal(:fulfilled, state)
    assert_equal(true, result["done"])
  end

  # A signal shared by many fetches keeps none of them once each has settled
  # and its body has been read (or the fetch failed).
  def test_a_signal_lets_go_of_a_settled_fetch
    controller = Dommy::AbortController.new
    signal = controller.signal
    _, response = outcome(fetch("/search", {"signal" => signal}))
    outcome(response.__js_call__("text", []))
    outcome(fetch("https://elsewhere.test/x", {"signal" => signal, "mode" => "same-origin"}))

    assert_empty(signal.instance_variable_get(:@abort_algorithms))
  end

  def test_an_abort_clears_a_delayed_stubs_timer
    @win.globals.delete("__fetch_handler__")
    @win.globals["__fetchy_stub__"] = {"/slow" => {"body" => "late", "delay" => 100}}
    controller = Dommy::AbortController.new
    promise = fetch("/slow", {"signal" => controller.signal})
    @win.scheduler.advance_time(0)
    controller.__js_call__("abort", ["stale"])

    assert_equal([:rejected, "stale"], outcome(promise))
    assert_nil(@win.scheduler.next_due_timer_at)
  end
end
