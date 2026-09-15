# frozen_string_literal: true

require_relative "../test_helper"

# Range's stringifier concatenates the data of the Text nodes the range
# covers, and a CDATASection is a Text node. Range also has no containsNode;
# that operation belongs to Selection. Both match Chrome 149 and Firefox 155.
#
# Spec: https://dom.spec.whatwg.org/#dom-range-stringifier
class TestWPTRangeStringifierCdata < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @xml = Dommy::DOMParser.new.parse_from_string("<r>x<![CDATA[ab]]>y</r>", "application/xml")
    @root = @xml.document_element
  end

  def test_the_stringifier_includes_a_cdata_section
    range = @xml.create_range
    range.select_node_contents(@root)
    assert_equal("xaby", range.to_s)
  end

  def test_a_range_starting_inside_a_cdata_section
    range = @xml.create_range
    range.set_start(@root.child_nodes.to_a[1], 1)
    range.set_end(@root, 3)
    assert_equal("by", range.to_s)
  end

  def test_range_does_not_expose_contains_node
    refute_includes(@xml.create_range.__js_method_names__, "containsNode")
  end
end
