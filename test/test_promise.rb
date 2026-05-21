# frozen_string_literal: true

require_relative "test_helper"

class TestPromise < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @ctor = @win.__js_get__("Promise")
  end

  def test_resolve_delivers_value
    p = @ctor.__js_call__("resolve", [42])
    seen = []
    p.__js_call__("then", [proc { |v| seen << v }])
    @win.scheduler.drain_microtasks
    assert_equal([42], seen)
  end

  def test_reject_routes_to_on_error
    p = @ctor.__js_call__("reject", ["boom"])
    errs = []
    p.__js_call__("then", [nil, proc { |e| errs << e }])
    @win.scheduler.drain_microtasks
    assert_equal(["boom"], errs)
  end

  def test_then_chain_propagates
    p = @ctor.__js_call__("resolve", [1])
    final = []
    p
      .__js_call__("then", [proc { |v| v + 10 }])
      .__js_call__("then", [proc { |v| final << v }])
    @win.scheduler.drain_microtasks
    assert_equal([11], final)
  end

  def test_new_promise_with_executor
    promise = @ctor.__js_new__(
      [
        proc { |resolve, _reject|
          resolve.__js_call__("call", ["ok"])
        }
      ]
    )
    seen = []
    promise.__js_call__("then", [proc { |v| seen << v }])
    @win.scheduler.drain_microtasks
    assert_equal(["ok"], seen)
  end

  def test_promise_settles_after_set_timeout
    promise = @ctor.__js_new__(
      [
        proc { |resolve, _reject|
          @win.scheduler.set_timeout(proc { resolve.__js_call__("call", ["delayed"]) }, 30)
        }
      ]
    )
    seen = []
    promise.__js_call__("then", [proc { |v| seen << v }])

    @win.scheduler.advance_time(20)
    assert_empty(seen)

    @win.scheduler.advance_time(20)
    assert_equal(["delayed"], seen)
  end
end
