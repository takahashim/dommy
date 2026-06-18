# frozen_string_literal: true

require_relative "test_helper"

class TestMutationObserver < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
  end

  def test_observes_child_added_via_microtask
    records = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| records.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true}])

    @root.append_child(@doc.create_element("span"))
    @win.scheduler.drain_microtasks

    assert_equal(1, records.size)
    assert_equal("childList", records.first.__js_get__("type"))
    assert_equal(1, records.first.__js_get__("addedNodes").size)
  end

  def test_a_throwing_callback_does_not_escape_or_stop_other_observers
    ran_other = false
    bad = Dommy::MutationObserver.new(@win, proc { |_recs| raise "boom in observer" })
    good = Dommy::MutationObserver.new(@win, proc { |_recs| ran_other = true })
    bad.__js_call__("observe", [@root, {"childList" => true}])
    good.__js_call__("observe", [@root, {"childList" => true}])

    @root.append_child(@doc.create_element("span"))
    # WHATWG: a throwing observer callback is reported but must not escape its
    # dispatch or abort the notify loop. Draining stays clean and the sibling
    # observer still delivers — a page's JS isn't derailed by one broken observer.
    @win.scheduler.drain_microtasks

    assert ran_other, "the other observer still delivered after one threw"
  end

  def test_subtree_option
    records = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| records.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true, "subtree" => true}])

    nested = @doc.create_element("div")
    @root.append_child(nested)
    nested.append_child(@doc.create_element("span"))
    @win.scheduler.drain_microtasks

    assert_operator(records.size, :>=, 2)
  end

  def test_disconnect_stops_delivery
    records = []
    obs = Dommy::MutationObserver.new(@win, proc { |recs| records.concat(recs) })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    obs.__js_call__("disconnect", [])

    @root.append_child(@doc.create_element("span"))
    @win.scheduler.drain_microtasks

    assert_empty(records)
  end

  def test_take_records_drains_queue
    obs = Dommy::MutationObserver.new(@win, proc { |_| })
    obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("span"))

    taken = obs.__js_call__("takeRecords", [])
    assert_equal(1, taken.size)

    # Subsequent drain shouldn't re-deliver what was taken.
    delivered = []
    obs.instance_variable_set(:@callback, proc { |r| delivered.concat(r) })
    @win.scheduler.drain_microtasks
    assert_empty(delivered)
  end
end
