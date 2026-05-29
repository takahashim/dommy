# frozen_string_literal: true

require_relative "../test_helper"

class TestObserverMatcher < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><div id='middle'><span id='inner'>X</span></div></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @middle = @doc.get_element_by_id("middle")
    @inner = @doc.get_element_by_id("inner")
    @matcher = Dommy::Internal::ObserverMatcher.new
  end

  def test_matches_exact_target
    assert(@matcher.matches?(@middle, @middle, subtree: false))
    assert(@matcher.matches?(@middle, @middle, subtree: true))
  end

  def test_does_not_match_descendant_without_subtree
    refute(@matcher.matches?(@outer, @inner, subtree: false))
  end

  def test_matches_descendant_with_subtree
    assert(@matcher.matches?(@outer, @inner, subtree: true))
    assert(@matcher.matches?(@outer, @middle, subtree: true))
  end

  def test_does_not_match_ancestor_with_subtree
    refute(@matcher.matches?(@inner, @outer, subtree: true))
  end

  def test_does_not_match_unrelated_nodes
    sibling = @doc.create_element("aside")
    refute(@matcher.matches?(@outer, sibling, subtree: true))
    refute(@matcher.matches?(@outer, sibling, subtree: false))
  end

  def test_matches_document_returns_true_only_with_subtree
    target = @inner
    assert(@matcher.matches_document?(target, subtree: true))
    refute(@matcher.matches_document?(target, subtree: false))
  end

  def test_matches_handles_observed_without_contains_method
    # Build an object that has no contains?
    fake_observed = Object.new
    refute(@matcher.matches?(fake_observed, @inner, subtree: true))
  end
end
