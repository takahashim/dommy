# frozen_string_literal: true

require_relative "test_helper"

# WebIDL converts a method's arguments before its steps run: an integer type
# through ECMAScript ToNumber (StringToNumber's grammar for a string), an
# interface type by checking the value implements it.
class TestWebIDLArgumentConversion < Minitest::Test
  include DommyTestHelper

  WEBIDL = Dommy::Internal::WebIDL

  def setup
    @doc = make_window('<div id="d">abcdef</div>').document
    @div = @doc.get_element_by_id("d")
    @text = @div.first_child
  end

  # The values lean4-dom's findings 62 found read differently, and their
  # neighbours: what ToNumber makes of them, then ConvertToInt.
  def test_to_number_follows_string_to_number
    {
      true => 1, [2] => 2, "0b11" => 3, "0o7" => 7, "0X1f" => 31, "1_0" => 0, "-0x1" => 0,
      "\u00A05\u3000" => 5, "\uFEFF6" => 6, "\u200B8" => 0, nil => 0, false => 0, "" => 0,
      " \t" => 0, ".5e1" => 5, "5." => 5, "Infinity" => 0, {} => 0, "+7" => 7, "-1" => 4_294_967_295,
      "0b" => 0, "." => 0, "e5" => 0, [] => 0, ["3", nil] => 0, 4_294_967_298.7 => 2
    }.each do |value, expected|
      assert_equal expected, WEBIDL.unsigned_long(value), value.inspect
    end
    assert_equal 65_535, WEBIDL.unsigned_short(-1)
    assert_equal(-Float::INFINITY, WEBIDL.to_number("-Infinity"))
  end

  # CharacterData's offsets and count and Range's offsets and `how` all take
  # the one conversion.
  def test_every_integer_argument_converts_the_same
    assert_equal "b", @text.substring_data(true, "0o1")
    assert_equal "c", @text.substring_data([2], 1)
    assert_equal "a", @text.substring_data("\u3000 0 ", 1)

    range = @doc.create_range
    range.set_start(@text, "0b11")
    assert_equal 3, range.start_offset
    range.set_end(@text, "\u00A04")
    assert_equal "d", range.to_s
    assert_equal 0, range.compare_boundary_points("0x0", range)
  end

  def test_compare_document_position_needs_a_node
    assert_raises(Dommy::Bridge::TypeError) { @div.compare_document_position(nil) }
    assert_raises(Dommy::Bridge::TypeError) { @div.compare_document_position("x") }
  end

  # The reference child is a `Node?`: null is fine, a non-node is not.
  def test_insert_before_converts_both_arguments
    [@div, @doc.create_document_fragment, @div.attach_shadow("mode" => "open")].each do |parent|
      assert_raises(Dommy::Bridge::TypeError) { parent.insert_before(@doc.create_element("p"), "x") }
      assert_raises(Dommy::Bridge::TypeError) { parent.insert_before(nil, nil) }
      parent.insert_before(@doc.create_element("p"), nil)
    end
    assert_raises(Dommy::Bridge::TypeError) { @doc.insert_before(@doc.create_comment("c"), {}) }
  end

  def test_observe_needs_a_node_target
    observer = Dommy::MutationObserver.new(@doc.default_view, proc {})
    assert_raises(Dommy::Bridge::TypeError) { observer.__js_call__("observe", [true, {"childList" => true}]) }
  end

  def test_set_attribute_node_needs_an_attr
    [nil, "x", @div].each do |value|
      assert_raises(Dommy::Bridge::TypeError) { @div.set_attribute_node(value) }
      assert_raises(Dommy::Bridge::TypeError) { @div.set_attribute_node_ns(value) }
    end
  end
end
