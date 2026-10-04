# frozen_string_literal: true

require_relative "test_helper"

# A callback is a JS function (a Js::Callable) or a Ruby callable — told by
# type, since every host object answers __js_call__ for its own methods.
class TestCallableInvoker < Minitest::Test
  def setup
    @doc = Dommy.parse("<p id=p>x</p>").document
  end

  def test_a_host_object_is_no_callback
    element = @doc.get_element_by_id("p")
    refute Dommy::CallableInvoker.callable?(element)
    refute Dommy::CallableInvoker.js_callable?(element)
    assert_nil Dommy::CallableInvoker.invoke(element, 1)
    assert Dommy::CallableInvoker.callable?(->(*) {})
  end

  # resolve and reject from `new Promise(executor)` are Ruby callables, so
  # they serve as a callback anywhere one is taken.
  def test_a_promise_settler_is_a_ruby_callable
    window = Dommy.parse("<p>").document.default_view
    promise = Dommy::PromiseValue.new(window)
    resolve = Dommy::Bridge::PromiseSettler.new(promise, fulfilled: true)
    assert Dommy::CallableInvoker.callable?(resolve)
    Dommy::CallableInvoker.invoke(resolve, 42)
    assert_equal 42, promise.await
  end
end
