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
    assert_raises(TypeError) { @obs.__js_call__("observe", [@root, {}]) }
  end

  def test_observe_with_only_subtree_raises
    assert_raises(TypeError) do
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

  def test_records_accessor
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    assert_equal(1, @obs.records.size)
  end
end
