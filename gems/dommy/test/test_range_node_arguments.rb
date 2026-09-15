# frozen_string_literal: true

require_relative "test_helper"

# WebIDL converts a method's arguments before any of its steps run. Every Node
# argument of Range is non-nullable, so null, undefined, or any other non-Node is
# a TypeError — not an exception from a later step, and not a range whose
# container is null.
#
# Spec: https://webidl.spec.whatwg.org/#js-interface
#       https://dom.spec.whatwg.org/#interface-range
class TestRangeNodeArguments < Minitest::Test
  include DommyTestHelper

  NOT_NODES = [nil, Dommy::Bridge::UNDEFINED, "x"].freeze
  NODE_AND_OFFSET_METHODS = %w[setStart setEnd comparePoint isPointInRange].freeze
  NODE_METHODS = %w[
    setStartBefore setStartAfter setEndBefore setEndAfter selectNode selectNodeContents
    insertNode surroundContents intersectsNode
  ].freeze

  def setup
    @win = make_window("<div id='host'><p id='p'>text</p></div>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
    @text = @p.first_child
    @range = @doc.create_range
    @range.set_start(@text, 1)
    @range.set_end(@text, 3)
  end

  def assert_type_error_leaving_range_alone(method, args)
    assert_raises(Dommy::Bridge::TypeError, "#{method}(#{args.inspect})") { @range.__js_call__(method, args) }
    assert_same(@text, @range.start_container)
    assert_equal(1, @range.start_offset)
    assert_same(@text, @range.end_container)
    assert_equal(3, @range.end_offset)
  end

  def test_node_and_offset_methods_reject_a_non_node
    NODE_AND_OFFSET_METHODS.product(NOT_NODES).each do |method, value|
      assert_type_error_leaving_range_alone(method, [value, 0])
    end
  end

  def test_node_methods_reject_a_non_node
    NODE_METHODS.product(NOT_NODES).each do |method, value|
      assert_type_error_leaving_range_alone(method, [value])
    end
  end

  def test_a_missing_argument_is_a_type_error
    assert_type_error_leaving_range_alone("selectNode", [])
  end

  # The conversion comes first, so a bad offset alongside it goes unreported.
  def test_set_start_reports_the_node_before_the_offset
    assert_type_error_leaving_range_alone("setStart", [nil, 999])
  end

  # insertNode splits a Text start node in step 6; a rejected argument must not
  # get that far.
  def test_insert_node_does_not_split_before_rejecting
    assert_type_error_leaving_range_alone("insertNode", [nil])
    assert_equal(1, @p.child_nodes.length)
    assert_equal("text", @text.data)
  end

  def test_the_ruby_api_converts_too
    assert_raises(Dommy::Bridge::TypeError) { @range.select_node_contents(nil) }
    assert_raises(Dommy::Bridge::TypeError) { @range.set_start(nil, 0) }
  end

  # `sourceRange` is converted along with `how`, so it is reported before step
  # 1's NotSupportedError for an unknown `how`.
  def test_compare_boundary_points_rejects_a_non_range_before_checking_how
    assert_raises(Dommy::Bridge::TypeError) { @range.__js_call__("compareBoundaryPoints", [99, nil]) }
    assert_raises(Dommy::Bridge::TypeError) { @range.__js_call__("compareBoundaryPoints", [0, @p]) }
    assert_raises(Dommy::DOMException::NotSupportedError) do
      @range.__js_call__("compareBoundaryPoints", [99, @doc.create_range])
    end
  end

  # Selection.collapse takes a `Node?`: null is not an error but a request to
  # clear the selection.
  def test_selection_collapse_to_null_removes_all_ranges
    selection = @doc.get_selection
    selection.collapse(@text, 1)
    assert_equal(1, selection.range_count)

    selection.__js_call__("collapse", [nil, 0])
    assert_equal(0, selection.range_count)
    assert_nil(selection.anchor_node)
  end

  def test_selection_collapse_rejects_a_non_node
    selection = @doc.get_selection
    assert_raises(Dommy::Bridge::TypeError) { selection.__js_call__("collapse", ["x", 0]) }
    assert_equal(0, selection.range_count)
  end
end
