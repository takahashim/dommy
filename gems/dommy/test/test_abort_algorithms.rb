# frozen_string_literal: true

require_relative "test_helper"

# What an abort algorithm throws (Observable.from()'s IteratorClose, over the
# bridge) reaches the caller of abort(), but only once every abort step has
# run: the remaining algorithms, the "abort" event, and the dependent
# signals' steps. A Ruby algorithm's own error stays inside.
class TestAbortAlgorithms < Minitest::Test
  def test_abort_throws_the_first_thrown_value_after_every_step
    controller = Dommy::AbortController.new
    dependent = Dommy::AbortSignal.any([controller.signal])
    log = []
    controller.signal.__internal_add_abort_algorithm__(proc { log << :first; raise Dommy::Bridge::ThrowValue, "first" })
    controller.signal.__internal_add_abort_algorithm__(proc { log << :second; raise Dommy::Bridge::ThrowValue, "second" })
    controller.signal.add_event_listener("abort", proc { log << :event })
    dependent.__internal_add_abort_algorithm__(proc { log << :dependent; raise Dommy::Bridge::ThrowValue, "dependent" })
    dependent.add_event_listener("abort", proc { log << :dependent_event })

    error = assert_raises(Dommy::Bridge::ThrowValue) { controller.__js_call__("abort", []) }

    assert_equal("first", error.value)
    assert_equal(%i[first second event dependent dependent_event], log)
    assert_predicate(controller.signal, :aborted?)
  end

  def test_a_dependent_signals_thrown_value_reaches_abort
    controller = Dommy::AbortController.new
    dependent = Dommy::AbortSignal.any([controller.signal])
    dependent.__internal_add_abort_algorithm__(proc { raise Dommy::Bridge::ThrowValue, "dependent" })

    error = assert_raises(Dommy::Bridge::ThrowValue) { controller.__js_call__("abort", []) }

    assert_equal("dependent", error.value)
  end

  def test_a_ruby_algorithms_error_does_not_escape
    controller = Dommy::AbortController.new
    ran = []
    controller.signal.__internal_add_abort_algorithm__(proc { raise "Ruby bug" })
    controller.signal.__internal_add_abort_algorithm__(proc { ran << :next })

    controller.__js_call__("abort", [])

    assert_equal([:next], ran)
  end
end
