# frozen_string_literal: true

require_relative "test_helper"

# A document consults every NodeIterator it tracks on every node removal, and
# `detach()` is a no-op by definition — so the only thing that can ever stop an
# iterator costing work is being collected. Tracking them in a plain Array meant
# every iterator ever created kept being consulted for the life of the document,
# and kept its referenceNode's whole detached subtree alive with it. Live ranges
# were already tracked weakly; this is the same rule for iterators.
#
# Spec: https://dom.spec.whatwg.org/#nodeiterator-pre-removing-steps
class TestNodeIteratorRetention < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='c'><p id='p'>text</p></div>")
    @doc = @win.document
    @container = @doc.get_element_by_id("c")
  end

  def tracked
    @doc.instance_variable_get(:@node_iterators).size
  end

  # Created in a method that returns nothing, so the caller keeps no reference
  # to the last one — CRuby's stack scanning would otherwise pin it.
  def make_iterators(count)
    count.times { @doc.create_node_iterator(@container) }
    nil
  end

  # One GC.start is not enough: its own frame still reaches what the line above
  # allocated, so the second pass is the one that collects it.
  def collect
    2.times { GC.start }
  end

  def test_an_iterator_still_in_use_keeps_getting_its_pre_removing_steps
    iterator = @doc.create_node_iterator(@container)
    iterator.next_node
    iterator.next_node
    paragraph = @doc.get_element_by_id("p")

    assert paragraph.contains?(iterator.instance_variable_get(:@reference_node))

    @container.remove_child(paragraph)

    refute paragraph.contains?(iterator.instance_variable_get(:@reference_node))
    assert_same @container, iterator.instance_variable_get(:@reference_node)
  end

  def test_iterators_that_went_out_of_scope_stop_being_tracked
    make_iterators(200)
    held = @doc.create_node_iterator(@container)
    collect
    # Not zero: CRuby's stack scanning pins the most recent allocation or two,
    # which is why this asserts the count collapses rather than an exact figure.
    assert_operator tracked, :<=, 2, "collected iterators must stop being tracked"
    assert_operator tracked, :>=, 1, "a referenced iterator must stay tracked"
    refute_nil held
  end

  # The invariant, stated without depending on when a GC runs: a document tracks
  # its iterators exactly the way it tracks its live ranges.
  def test_iterators_are_tracked_the_same_way_live_ranges_are
    @doc.create_range
    @doc.create_node_iterator(@container)

    assert_kind_of ObjectSpace::WeakMap, @doc.instance_variable_get(:@node_iterators)
    assert_kind_of ObjectSpace::WeakMap, @doc.instance_variable_get(:@live_ranges)
  end

  # An iterator rooted in another document is tracked by THAT document, which is
  # where its removals fire.
  def test_an_iterator_rooted_in_another_document_is_tracked_there
    other = @doc.implementation.create_html_document("other")
    iterator = other.create_node_iterator(other.body)

    assert_equal 0, tracked
    assert_operator other.instance_variable_get(:@node_iterators).size, :>=, 1
    refute_nil iterator
  end
end
