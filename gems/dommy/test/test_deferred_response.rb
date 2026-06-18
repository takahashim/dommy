# frozen_string_literal: true

require_relative "test_helper"

# The async-network handoff: a handler that returns a DeferredResponse resolves
# fetch/XHR off the page thread, with the response applied on the page thread via
# the scheduler's external inbox.
class TestDeferredResponse < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @sched = @win.scheduler
  end

  def test_delivers_on_the_page_thread_after_a_drain
    deferred = Dommy::DeferredResponse.new(@sched)
    got = []
    deferred.on_complete { |entry| got << entry }

    Thread.new { deferred.complete({"status" => 200}) }.join # worker delivers
    assert_empty got, "not delivered until the loop drains"

    @sched.advance_time(0)
    assert_equal [{"status" => 200}], got
  end

  # complete() arriving before on_complete (a fast worker) still delivers once.
  def test_complete_before_register_still_delivers_once
    deferred = Dommy::DeferredResponse.new(@sched)
    deferred.complete({"status" => 204})
    got = []
    deferred.on_complete { |entry| got << entry }
    @sched.advance_time(0)
    assert_equal [{"status" => 204}], got

    deferred.complete({"status" => 500}) # late duplicate -> ignored (one-shot)
    @sched.advance_time(0)
    assert_equal [{"status" => 204}], got
  end

  # fetch() to a handler that defers stays pending until the worker completes and
  # the loop drains, then resolves on the page thread.
  def test_fetch_resolves_an_async_deferred_response
    deferred = Dommy::DeferredResponse.new(@sched)
    @win.__js_set__("__fetch_handler__", ->(_url, _init) { deferred })

    promise = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/async", nil])

    # Resolves only after the worker completes AND the loop drains the inbox —
    # i.e. the request was genuinely deferred, not answered inline.
    Thread.new { deferred.complete({"status" => 201, "body" => "async-body"}) }.join
    @sched.advance_time(0)

    response = promise.await
    assert_equal 201, response.__js_get__("status")
    assert_equal "async-body", response.__js_call__("text", []).await
  end

  # XMLHttpRequest takes the same deferred path: it stays open until the
  # off-thread response arrives, then delivers on the page thread.
  def test_xhr_resolves_an_async_deferred_response
    deferred = Dommy::DeferredResponse.new(@sched)
    @win.__js_set__("__fetch_handler__", ->(_url, _init) { deferred })

    xhr = Dommy::XMLHttpRequest.new(@win)
    xhr.open("GET", "/async", true)
    xhr.send
    refute_equal 4, xhr.ready_state, "still open until the response arrives" # 4 = DONE

    Thread.new { deferred.complete({"status" => 200, "body" => "async-xhr"}) }.join
    @sched.advance_time(0)

    assert_equal 4, xhr.ready_state
    assert_equal 200, xhr.status
    assert_equal "async-xhr", xhr.response_text
  end

  # A deferred that completes with nil (a network failure) fulfills as a 404-style
  # miss, like a synchronous miss.
  def test_deferred_nil_completion_is_a_miss
    deferred = Dommy::DeferredResponse.new(@sched)
    @win.__js_set__("__fetch_handler__", ->(_url, _init) { deferred })

    promise = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/gone", nil])
    deferred.complete(nil)
    @sched.advance_time(0)

    assert_equal 404, promise.await.__js_get__("status")
  end
end
