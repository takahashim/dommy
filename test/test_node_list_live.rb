# frozen_string_literal: true

require_relative "test_helper"

# NodeList spec compliance + LiveNodeList behavior.
class TestNodeListSpec < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<ul><li id='a'></li><li id='b'></li><li id='c'></li></ul>")
    @doc = @win.document
    @list = @doc.query_selector_all("li")
  end

  def test_returned_collection_is_NodeList
    assert_kind_of(Dommy::NodeList, @list)
  end

  def test_length
    assert_equal(3, @list.length)
  end

  def test_item_in_range
    assert_equal("a", @list.item(0).id)
    assert_equal("c", @list.item(2).id)
  end

  def test_item_out_of_range_returns_nil
    assert_nil(@list.item(99))
  end

  def test_item_negative_returns_nil
    # Spec: item(i) takes unsigned long → negative becomes huge → nil.
    # We chose to return nil for any negative.
    assert_nil(@list.item(-1))
  end

  def test_for_each_yields_value_index_list
    seen = []
    @list.for_each { |v, i, l| seen << [v.id, i, l.equal?(@list)] }
    assert_equal([["a", 0, true], ["b", 1, true], ["c", 2, true]], seen)
  end

  def test_for_each_returns_nil
    assert_nil(@list.for_each { |_v, _i, _l| nil })
  end

  def test_keys_returns_indices
    assert_equal([0, 1, 2], @list.keys)
  end

  def test_values_returns_node_array
    vals = @list.values
    assert_kind_of(Array, vals)
    assert_equal("a", vals[0].id)
  end

  def test_entries_pairs_index_value
    e = @list.entries
    assert_equal([0, "a"], [e[0][0], e[0][1].id])
  end

  def test_js_bridge_length
    assert_equal(3, @list.__js_get__("length"))
  end

  def test_js_bridge_index_access
    assert_equal("b", @list.__js_get__("1").id)
    assert_equal("b", @list.__js_get__(1).id)
  end

  def test_js_bridge_item_call
    assert_equal("a", @list.__js_call__("item", [0]).id)
  end

  def test_js_bridge_forEach_call
    seen = []
    @list.__js_call__("forEach", [proc { |v, i, _| seen << [v.id, i] }])
    assert_equal([["a", 0], ["b", 1], ["c", 2]], seen)
  end
end

class TestLiveNodeList < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<ul id='u'><li>A</li></ul>")
    @doc = @win.document
    @ul = @doc.get_element_by_id("u")
  end

  def test_live_child_nodes_reflects_append
    live = @ul.live_child_nodes
    assert_equal(1, live.length)
    @ul.append_child(@doc.create_element("li"))
    assert_equal(2, live.length)
  end

  def test_live_child_nodes_reflects_removal
    @ul.append_child(@doc.create_element("li"))
    live = @ul.live_child_nodes
    before = live.length
    @ul.first_child.remove
    assert_equal(before - 1, live.length)
  end

  def test_live_item_re_evaluates_each_call
    live = @ul.live_child_nodes
    first_before = live.item(0)
    @ul.prepend(@doc.create_element("p"))
    first_after = live.item(0)
    refute_same(first_before, first_after)
    assert_equal("P", first_after.tag_name)
  end

  def test_live_iteration_uses_current_state
    live = @ul.live_child_nodes
    @ul.append_child(@doc.create_element("li"))
    @ul.append_child(@doc.create_element("li"))
    assert_equal(3, live.to_a.length)
  end

  def test_live_for_each_yields_current_state
    live = @ul.live_child_nodes
    @ul.append_child(@doc.create_element("li"))
    seen = 0
    live.for_each { |_v, _i, _l| seen += 1 }
    assert_equal(2, seen)
  end

  def test_live_first_last
    live = @ul.live_child_nodes
    assert_equal("LI", live.first.tag_name)
    @ul.append_child(@doc.create_element("p"))
    assert_equal("P", live.last.tag_name)
  end

  def test_live_empty_initially
    div = @doc.create_element("div")
    @doc.body.append(div)
    live = div.live_child_nodes
    assert(live.empty?)
    assert_equal(0, live.length)
  end

  def test_live_js_bridge_length_re_evaluates
    live = @ul.live_child_nodes
    assert_equal(1, live.__js_get__("length"))
    @ul.append_child(@doc.create_element("li"))
    assert_equal(2, live.__js_get__("length"))
  end
end
