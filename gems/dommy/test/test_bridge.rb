# frozen_string_literal: true

require_relative "test_helper"

class TestBridgePromiseConstructor < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @pc = @win.__js_get__("Promise")
  end

  def test_promise_constructor_lives_under_bridge_namespace
    assert(defined?(Dommy::Bridge::PromiseConstructor))
    assert_kind_of(Dommy::Bridge::PromiseConstructor, @pc)
  end

  def test_resolve_class_method
    p = @pc.__js_call__("resolve", ["ok"])
    seen = nil
    p.__js_call__("then", [proc { |v| seen = v }])
    @win.scheduler.drain_microtasks
    assert_equal("ok", seen)
  end

  def test_new_promise_executor
    promise = @pc.__js_new__(
      [
        proc { |resolve, _reject|
          resolve.__js_call__("call", ["delivered"])
        }
      ]
    )
    seen = nil
    promise.__js_call__("then", [proc { |v| seen = v }])
    @win.scheduler.drain_microtasks
    assert_equal("delivered", seen)
  end
end
