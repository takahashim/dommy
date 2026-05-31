# frozen_string_literal: true

require_relative "test_helper"

class TestPromiseAwait < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  # --- Resolved / rejected synchronously ----------------------------

  def test_await_returns_fulfilled_value
    promise = Dommy::PromiseValue.resolve(@win, "hello")
    assert_equal("hello", promise.await)
  end

  def test_await_raises_rejected_reason
    promise = Dommy::PromiseValue.reject(@win, "boom")
    err = assert_raises(RuntimeError) { promise.await }
    assert_match(/boom/, err.message)
  end

  def test_await_re_raises_exception_rejection
    err = ArgumentError.new("nope")
    promise = Dommy::PromiseValue.reject(@win, err)
    raised = assert_raises(ArgumentError) { promise.await }
    assert_same(err, raised)
  end

  # --- Microtask-driven settlement ----------------------------------

  def test_await_drains_pending_microtasks
    promise = Dommy::PromiseValue.new(@win)
    @win.scheduler.queue_microtask(proc { promise.fulfill("microtask") })
    # promise is still pending here; await should drain microtasks and settle it
    assert_equal("microtask", promise.await)
  end

  def test_await_resolves_then_chain
    base = Dommy::PromiseValue.resolve(@win, 1)
    chained = base.__js_call__("then", [proc { |v| v + 10 }])
    assert_equal(11, chained.await)
  end

  # --- Pending state -----------------------------------------------

  def test_await_raises_when_still_pending_after_drain
    promise = Dommy::PromiseValue.new(@win)
    @win.scheduler.set_timeout(proc { promise.fulfill("late") }, 100)
    # No microtask is queued, so await sees it still pending.
    err = assert_raises(RuntimeError) { promise.await }
    assert_match(/pending/, err.message)
  end

  def test_await_succeeds_after_advance_time
    promise = Dommy::PromiseValue.new(@win)
    @win.scheduler.set_timeout(proc { promise.fulfill("on time") }, 50)
    @win.scheduler.advance_time(50)
    assert_equal("on time", promise.await)
  end

  # --- Composability with fetch (sanity check) ---------------------

  def test_await_works_with_fetch_response
    @win.globals["__fetchy_stub__"] = {"/api" => {"body" => "ok", "status" => 200}}
    fetch = Dommy::FetchFn.new(@win)
    response = fetch.__js_call__("fetch", ["/api"]).await
    assert_equal(200, response.__js_get__("status"))
    # `.body` is a ReadableStream now; read the body text via the spec method.
    assert_equal("ok", response.__js_call__("text", []).await)
  end
end
