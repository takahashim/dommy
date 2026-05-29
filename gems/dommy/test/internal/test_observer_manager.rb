# frozen_string_literal: true

require_relative "../test_helper"

class TestObserverManager < Minitest::Test
  # Fake observer that records calls to matches_wrapped?
  class FakeObserver
    attr_reader :match_calls

    def initialize(matches_for: [])
      @matches_for = matches_for
      @match_calls = []
    end

    def matches_wrapped?(target)
      @match_calls << target
      @matches_for.include?(target)
    end
  end

  def setup
    @manager = Dommy::Internal::ObserverManager.new
  end

  def test_register_adds_observer
    obs = FakeObserver.new
    @manager.register(obs)
    assert_includes(@manager.all, obs)
  end

  def test_register_is_idempotent
    obs = FakeObserver.new
    @manager.register(obs)
    @manager.register(obs)
    assert_equal(1, @manager.all.size)
  end

  def test_unregister_removes_observer
    obs = FakeObserver.new
    @manager.register(obs)
    @manager.unregister(obs)
    refute_includes(@manager.all, obs)
  end

  def test_observers_matching_returns_only_matching_observers
    target = Object.new
    matching = FakeObserver.new(matches_for: [target])
    non_matching = FakeObserver.new(matches_for: [])
    @manager.register(matching)
    @manager.register(non_matching)

    result = @manager.observers_matching(target)
    assert_includes(result, matching)
    refute_includes(result, non_matching)
  end

  def test_all_returns_a_copy
    obs = FakeObserver.new
    @manager.register(obs)
    list = @manager.all
    list.clear
    assert_includes(@manager.all, obs)
  end
end
