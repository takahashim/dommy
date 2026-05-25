# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for MutationObserver.
# WPT: dom/nodes/MutationObserver-*.html
class TestWPTMutationObserverChildList < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @records = []
    @obs = Dommy::MutationObserver.new(@win, proc { |recs| @records.concat(recs) })
  end

  def teardown
    @obs.__js_call__("disconnect", [])
  end

  # ---- childList ----
  # WPT: MutationObserver-childList.html

  def test_observe_requires_at_least_one_flag
    assert_raises(TypeError) { @obs.__js_call__("observe", [@root, {}]) }
  end

  def test_childList_records_appended_node
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    assert_equal("childList", @records.first.__js_get__("type"))
  end

  def test_childList_records_addedNodes
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    el = @doc.create_element("span")
    @root.append_child(el)
    @win.scheduler.drain_microtasks
    assert_equal([el], @records.first.__js_get__("addedNodes"))
  end

  def test_childList_records_removedNodes
    @root.append_child(@doc.create_element("p"))
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    removed = @root.first_element_child
    removed.remove
    @win.scheduler.drain_microtasks
    assert_equal([removed], @records.first.__js_get__("removedNodes"))
  end

  def test_childList_records_target_is_parent
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    @win.scheduler.drain_microtasks
    assert_same(@root, @records.first.__js_get__("target"))
  end

  def test_childList_without_subtree_ignores_grandchild_mutation
    nested = @doc.create_element("div")
    @root.append_child(nested)
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @win.scheduler.drain_microtasks
    @records.clear
    nested.append_child(@doc.create_element("span"))
    @win.scheduler.drain_microtasks
    assert_empty(@records)
  end

  def test_childList_with_subtree_observes_grandchild
    nested = @doc.create_element("div")
    @root.append_child(nested)
    @obs.__js_call__("observe", [@root, {"childList" => true, "subtree" => true}])
    @win.scheduler.drain_microtasks
    @records.clear
    nested.append_child(@doc.create_element("span"))
    @win.scheduler.drain_microtasks
    refute_empty(@records)
  end

  # ---- TextNode / CommentNode remove triggers childList ----
  # Regression: CharacterDataNode#remove previously called
  # @__node__.unlink without notifying the MutationObserver, so
  # removing a text or comment node was silent.
  # WPT: dom/nodes/MutationObserver-characterData.html
  # (text removal is observed via the parent's childList list).

  def test_childList_records_text_node_removal
    text = @doc.create_text_node("hello")
    @root.append_child(text)
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    text.remove
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    assert_equal([text], @records.first.__js_get__("removedNodes"))
  end

  def test_childList_records_comment_node_removal
    comment = @doc.create_comment("note")
    @root.append_child(comment)
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    comment.remove
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    assert_equal([comment], @records.first.__js_get__("removedNodes"))
  end

  # ---- textContent= triggers childList ----
  # Regression: setting textContent removes all existing children
  # and (for non-empty values) appends one text node. Both halves
  # must be reflected in a MutationRecord.
  # WPT: dom/nodes/MutationObserver-childList.html (textContent cases)

  def test_textContent_set_to_non_empty_records_removal_and_addition
    @root.append_child(@doc.create_element("span"))
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.__js_set__("textContent", "hello")
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    rec = @records.first
    refute_empty(rec.__js_get__("removedNodes"))
    refute_empty(rec.__js_get__("addedNodes"))
  end

  def test_textContent_set_to_empty_records_removal_only
    @root.append_child(@doc.create_element("span"))
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.__js_set__("textContent", "")
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    rec = @records.first
    refute_empty(rec.__js_get__("removedNodes"))
    assert_empty(rec.__js_get__("addedNodes"))
  end

  def test_textContent_on_empty_element_does_not_record
    # No existing children, value is "" -> nothing changes, no
    # record should be emitted (the notify call's empty-list guard
    # in MutationCoordinator covers this).
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.__js_set__("textContent", "")
    @win.scheduler.drain_microtasks
    assert_empty(@records)
  end
end

class TestWPTMutationObserverAttributes < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @records = []
    @obs = Dommy::MutationObserver.new(@win, proc { |recs| @records.concat(recs) })
  end

  def teardown
    @obs.__js_call__("disconnect", [])
  end

  # ---- attributes ----
  # WPT: MutationObserver-attributes.html

  def test_attributes_records_setAttribute
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.set_attribute("class", "x")
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    assert_equal("attributes", @records.first.__js_get__("type"))
  end

  def test_attributes_records_attributeName
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.set_attribute("data-y", "1")
    @win.scheduler.drain_microtasks
    assert_equal("data-y", @records.first.__js_get__("attributeName"))
  end

  def test_attributes_records_removeAttribute
    @root.set_attribute("class", "x")
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.remove_attribute("class")
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    assert_equal("class", @records.first.__js_get__("attributeName"))
  end

  def test_attributeOldValue_captures_previous
    @root.set_attribute("data-v", "old")
    @obs.__js_call__("observe", [@root, {"attributes" => true, "attributeOldValue" => true}])
    @root.set_attribute("data-v", "new")
    @win.scheduler.drain_microtasks
    assert_equal("old", @records.first.__js_get__("oldValue"))
  end

  def test_attributeFilter_restricts_to_listed
    @obs.__js_call__("observe", [@root, {"attributeFilter" => ["data-watched"]}])
    @root.set_attribute("data-other", "x")
    @root.set_attribute("data-watched", "y")
    @win.scheduler.drain_microtasks
    assert_equal(1, @records.size)
    assert_equal("data-watched", @records.first.__js_get__("attributeName"))
  end

  def test_attributeFilter_implies_attributes_true
    # Per spec, attributeFilter sets attributes=true implicitly.
    # Should not raise even without explicit "attributes" => true.
    @obs.__js_call__("observe", [@root, {"attributeFilter" => ["x"]}])
    assert(true)
  end
end

class TestWPTMutationObserverDelivery < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
  end

  # ---- microtask delivery ----
  # WPT: MutationObserver-document.html

  def test_records_delivered_in_microtask_not_sync
    records = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| records.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    # Before draining, callback should not have fired.
    assert_empty(records)
    @win.scheduler.drain_microtasks
    refute_empty(records)
  end

  def test_multiple_mutations_batched_into_single_callback
    callbacks = 0
    obs = Dommy::MutationObserver.new(@win, proc { callbacks += 1 })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    @root.append_child(@doc.create_element("p"))
    @root.append_child(@doc.create_element("p"))
    @win.scheduler.drain_microtasks
    assert_equal(1, callbacks)
  end

  # ---- disconnect ----
  # WPT: MutationObserver-disconnect.html

  def test_disconnect_stops_further_delivery
    records = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| records.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    obs.__js_call__("disconnect", [])
    @root.append_child(@doc.create_element("p"))
    @win.scheduler.drain_microtasks
    assert_empty(records)
  end

  def test_disconnect_after_mutation_clears_pending_records
    records = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| records.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    obs.__js_call__("disconnect", [])
    @win.scheduler.drain_microtasks
    assert_empty(records)
  end

  # ---- takeRecords ----
  # WPT: MutationObserver-takeRecords.html

  def test_takeRecords_returns_pending_and_clears
    obs = Dommy::MutationObserver.new(@win, proc { })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    taken = obs.__js_call__("takeRecords", [])
    assert_equal(1, taken.size)
    again = obs.__js_call__("takeRecords", [])
    assert_empty(again)
  end

  def test_takeRecords_prevents_callback_delivery
    delivered = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| delivered.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    obs.__js_call__("takeRecords", [])
    @win.scheduler.drain_microtasks
    assert_empty(delivered)
  end

  # ---- multiple observers ----

  def test_multiple_observers_each_receive_records
    a_records = []
    b_records = []
    obs_a = Dommy::MutationObserver.new(@win, proc { |r| a_records.concat(r) })
    obs_b = Dommy::MutationObserver.new(@win, proc { |r| b_records.concat(r) })
    obs_a.__js_call__("observe", [@root, {"childList" => true}])
    obs_b.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("p"))
    @win.scheduler.drain_microtasks
    refute_empty(a_records)
    refute_empty(b_records)
    obs_a.__js_call__("disconnect", [])
    obs_b.__js_call__("disconnect", [])
  end
end
