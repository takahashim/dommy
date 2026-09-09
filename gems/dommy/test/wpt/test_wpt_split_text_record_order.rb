# frozen_string_literal: true

require_relative "../test_helper"

# "Split a Text node" queues its characterData record BEFORE its childList one.
#
# Read literally, the algorithm's insertion (step 7.1) precedes the data
# replacement (step 8), which would put childList first — and that is what Dommy
# used to do. Every shipping engine does the opposite: Blink's Text::splitText
# calls DidModifyData before InsertBefore, WebCore matches it, and Gecko's
# Text::SplitText not only matches but says in a comment that nsRange DEPENDS on
# the data notification preceding the insertion.
#
# Confirmed by running the same script in all three (Chromium 141, WebKitGTK
# 2.52.6, Firefox): all answer [characterData, childList] for splitText and
# [childList, characterData] for the same two mutations performed explicitly, so
# the deviation is specific to splitText rather than a general reordering.
#
# WPT covers the split's RESULT (dom/nodes/Text-splitText.html) but never
# observes it, and neither MutationObserver-childList.html nor
# MutationObserver-characterData.html mentions splitText.
#
# Spec: https://dom.spec.whatwg.org/#concept-text-split
# Issue: https://github.com/takahashim/dommy/issues/23
class TestWPTSplitTextRecordOrder < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<b id='b'>abcdef</b>")
    @doc = @win.document
    @b = @doc.get_element_by_id("b")
  end

  def observe(target, **options)
    seen = []
    observer = Dommy::MutationObserver.new(@win, proc { |records| seen.concat(records) })
    observer.__js_call__("observe", [target, {"childList" => true, "characterData" => true, "subtree" => true}.merge(options)])
    yield
    @win.scheduler.drain_microtasks
    seen
  end

  def types(records)
    records.map { |record| record.__js_get__("type") }
  end

  def test_split_text_queues_character_data_before_child_list
    records = observe(@b) { @b.first_child.split_text(3) }

    assert_equal %w[characterData childList], types(records)
  end

  # The split itself is unchanged — only the record order moved.
  def test_the_split_result_is_unchanged
    @b.first_child.split_text(3)

    assert_equal %w[abc def], @b.child_nodes.map(&:data)
  end

  # The same two mutations performed explicitly still come back in execution
  # order. This is the control that makes the case above mean something: the
  # deviation is splitText's, not a general reordering of records.
  def test_the_same_two_mutations_done_explicitly_stay_in_execution_order
    text = @b.first_child
    records = observe(@b) do
      @b.append_child(@doc.create_text_node("def"))
      text.replace_data(3, 3, "")
    end

    assert_equal %w[childList characterData], types(records)
  end

  def test_the_records_carry_the_right_targets_and_nodes
    records = observe(@b) { @b.first_child.split_text(3) }
    character_data, child_list = records

    assert_same @b.first_child, character_data.__js_get__("target")
    assert_same @b, child_list.__js_get__("target")
    assert_equal 1, child_list.__js_get__("addedNodes").size
    assert_same @b.last_child, child_list.__js_get__("addedNodes")[0]
    assert_equal 0, child_list.__js_get__("removedNodes").size
  end

  def test_character_data_old_value_is_the_whole_string
    records = observe(@b, "characterDataOldValue" => true) { @b.first_child.split_text(3) }

    assert_equal "abcdef", records.first.__js_get__("oldValue")
  end

  # A detached Text node has no parent, so step 7 never runs: there is no
  # childList record to order against.
  def test_splitting_a_detached_node_queues_only_the_character_data_record
    text = @doc.create_text_node("abcdef")
    records = observe(text) { text.split_text(3) }

    assert_equal %w[characterData], types(records)
  end

  # A split at either boundary still splits, so it still queues both records in
  # the same order.
  def test_the_order_holds_at_both_boundaries
    assert_equal %w[characterData childList], types(observe(@b) { @b.first_child.split_text(0) })

    other = make_window("<b id='b'>abcdef</b>")
    element = other.document.get_element_by_id("b")
    seen = []
    observer = Dommy::MutationObserver.new(other, proc { |records| seen.concat(records) })
    observer.__js_call__("observe", [element, {"childList" => true, "characterData" => true, "subtree" => true}])
    element.first_child.split_text(6)
    other.scheduler.drain_microtasks

    assert_equal %w[characterData childList], seen.map { |record| record.__js_get__("type") }
  end

  # The live range steps did NOT move: they still run where the algorithm puts
  # them, so a boundary past the split point lands on the tail node.
  def test_live_range_boundaries_still_follow_the_algorithm
    range = @doc.create_range
    range.set_start(@b.first_child, 5)
    range.set_end(@b.first_child, 5)
    tail = @b.first_child.split_text(3)

    assert_same tail, range.start_container
    assert_equal 2, range.start_offset
    assert_equal 2, range.end_offset
  end

  def test_a_range_on_the_parent_past_the_split_still_shifts
    @b.append_child(@doc.create_element("i"))
    range = @doc.create_range
    range.set_start(@b, 1)
    range.set_end(@b, 1)
    @b.first_child.split_text(3)

    assert_same @b, range.start_container
    assert_equal 2, range.start_offset
  end
end
