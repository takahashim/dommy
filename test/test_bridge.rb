# frozen_string_literal: true

require_relative "test_helper"

class TestBridgeCallback < Minitest::Test
  def test_callback_lives_under_bridge_namespace
    assert(defined?(Dommy::Bridge::Callback))
  end

  def test_callback_id_via_id_key
    host = Class
      .new {
        def invoke_callback(_, _)
        end
      }
      .new
    cb = Dommy::Bridge::Callback.new(host, 42)
    assert_equal(42, cb.__js_get__("__callback_id__"))
  end

  def test_callback_invoke
    received = nil
    host = Class
      .new {
        define_method(:invoke_callback) { |id, args| received = [id, args] }
      }
      .new
    cb = Dommy::Bridge::Callback.new(host, 7)
    cb.__js_call__("call", [1, 2, 3])
    assert_equal([7, [1, 2, 3]], received)
  end

  def test_callback_set_get_arbitrary_props
    host = Class
      .new {
        def invoke_callback(_, _)
        end
      }
      .new
    cb = Dommy::Bridge::Callback.new(host, 1)
    cb.__js_set__("anyKey", "anyValue")
    assert_equal("anyValue", cb.__js_get__("anyKey"))
  end
end

class TestBridgeConstructor < Minitest::Test
  def test_constructor_lives_under_bridge_namespace
    assert(defined?(Dommy::Bridge::Constructor))
  end

  def test_js_new_invokes_block
    ctor = Dommy::Bridge::Constructor.new { |args| "result-#{args[0]}" }
    assert_equal("result-X", ctor.__js_new__(["X"]))
  end
end

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
