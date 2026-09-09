# frozen_string_literal: true

require_relative "test_helper"

# Round out MutationObserver coverage to match happy-dom's option
# normalization and edge cases.
class TestMutationObserverFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @records = []
    @obs = Dommy::MutationObserver.new(@win, proc { |recs| @records.concat(recs) })
  end

  def drain
    @win.scheduler.drain_microtasks
  end

  def test_observe_with_no_true_option_raises
    assert_raises(Dommy::Bridge::TypeError) { @obs.__js_call__("observe", [@root, {}]) }
  end

  def test_observe_with_only_subtree_raises
    assert_raises(Dommy::Bridge::TypeError) do
      @obs.__js_call__("observe", [@root, {"subtree" => true}])
    end
  end

  def test_attribute_filter_implies_attributes
    @obs.__js_call__("observe", [@root, {"attributeFilter" => ["data-x"]}])
    @root.set_attribute("data-x", "v")
    drain
    assert_equal(1, @records.size)
  end

  def test_attribute_old_value_implies_attributes
    @obs.__js_call__("observe", [@root, {"attributeOldValue" => true}])
    @root.set_attribute("data-x", "v1")
    @root.set_attribute("data-x", "v2")
    drain
    assert_operator(@records.size, :>=, 1)
  end

  def test_character_data_old_value_implies_character_data
    text = @doc.create_text_node("before")
    @root.append_child(text)
    @obs.__js_call__("observe", [text, {"characterDataOldValue" => true}])
    text.data = "after"
    drain
    assert_equal(1, @records.size)
    assert_equal("before", @records.first.__js_get__("oldValue"))
  end

  def test_subtree_character_data
    p = @doc.create_element("p")
    text = @doc.create_text_node("hello")
    p.append_child(text)
    @root.append_child(p)
    @obs.__js_call__("observe", [@root, {"characterData" => true, "subtree" => true}])
    text.data = "world"
    drain
    assert_equal(1, @records.size)
    assert_equal("characterData", @records.first.__js_get__("type"))
  end

  def test_observe_document_subtree
    @obs.__js_call__("observe", [@doc, {"childList" => true, "subtree" => true}])
    p = @doc.create_element("p")
    @root.append_child(p)
    drain
    assert_operator(@records.size, :>=, 1)
  end

  def test_take_records_clears_pending
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    taken = @obs.__js_call__("takeRecords", [])
    assert_equal(1, taken.size)
    drain
    # nothing left to deliver
    assert_empty(@records)
  end

  def test_disconnect_clears_pending
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    @obs.__js_call__("disconnect", [])
    drain
    assert_empty(@records)
  end

  # normalize() merges a run of text nodes one sibling at a time, the way every
  # shipping engine does: a characterData record on the survivor, then the
  # childList record for the sibling's removal, per sibling — not the single
  # characterData record a literal reading of the spec's batch steps would give.
  # https://github.com/takahashim/dommy/issues/24
  def test_normalize_queues_one_character_data_record_per_merged_sibling
    texts = %w[A BB CCC DDDD].map { |s| @root.append_child(@doc.create_text_node(s)) }
    @obs.__js_call__("observe", [@root, {
      "childList" => true, "characterData" => true, "characterDataOldValue" => true, "subtree" => true
    }])

    @root.normalize
    records = @obs.__js_call__("takeRecords", [])

    assert_equal(%w[characterData childList] * 3, records.map { |r| r.__js_get__("type") })
    assert_equal("ABBCCCDDDD", texts[0].data)
    data_records = records.each_slice(2).map(&:first)
    assert_equal(%w[A ABB ABBCCC], data_records.map { |r| r.__js_get__("oldValue") })
    assert(data_records.all? { |r| r.__js_get__("target").equal?(texts[0]) })
    removals = records.each_slice(2).map(&:last)
    assert_equal(texts[1..], removals.map { |r| r.__js_get__("removedNodes").to_a.first })
  end

  # An empty sibling in the run appends nothing, so — as in every engine — it is
  # removed without a characterData record, wherever it sits in the run.
  def test_normalize_queues_no_character_data_record_for_an_empty_sibling
    [["A", "", "B"], ["A", "B", ""]].each do |run|
      root = @doc.create_element("div")
      @root.append_child(root)
      run.each { |s| root.append_child(@doc.create_text_node(s)) }
      obs = Dommy::MutationObserver.new(@win, proc {})
      obs.__js_call__("observe", [root, {"childList" => true, "characterData" => true, "subtree" => true}])

      root.normalize
      types = obs.__js_call__("takeRecords", []).map { |r| r.__js_get__("type") }

      expected = run == ["A", "", "B"] ? %w[childList characterData childList] : %w[characterData childList childList]
      assert_equal(expected, types, run.inspect)
      assert_equal("AB", root.first_child.data)
    end
  end

  def test_records_accessor
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    assert_equal(1, @obs.records.size)
  end
end
