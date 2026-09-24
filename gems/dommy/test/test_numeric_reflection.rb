# frozen_string_literal: true

require_relative "test_helper"

# Reflected `long` and `unsigned long` IDL attributes (HTML §2.6.1). Which
# attributes these are, and with what default / range / sign, is checked against
# the specs' own IDL by test_webidl_conformance.rb; that the algorithm answers
# what a browser answers is checked by dommy-conformance's
# cases/attributes/numeric-reflection.js. This pins the same table here, where it
# runs without a browser.
# https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes
class TestNumericReflection < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window(<<~HTML).document
      <table><tr><td id="cell"></td></tr></table>
      <ol id="ol"><li id="li"></li></ol>
      <select id="select"></select><video id="video"></video>
    HTML
  end

  def read(id, attr, prop, value)
    element = @doc.get_element_by_id(id)
    value.nil? ? element.remove_attribute(attr) : element.set_attribute(attr, value)
    element.public_send(prop)
  end

  # HTML's rules for parsing integers collect a run of digits and return, so a
  # trailing suffix is ignored rather than making the value an error.
  def test_a_trailing_suffix_is_ignored_rather_than_an_error
    assert_equal(12, read("cell", "colspan", :col_span, "12abc"))
    assert_equal(1, read("cell", "colspan", :col_span, "1e3"))
    assert_equal(4, read("cell", "colspan", :col_span, "+4"))
    assert_equal(9, read("cell", "colspan", :col_span, "  9  "))
  end

  # No digits at all IS an error, and an error is what the default is for.
  def test_an_unparseable_value_falls_back_to_the_default
    assert_equal(1, read("cell", "colspan", :col_span, "abc"))
    assert_equal(1, read("cell", "colspan", :col_span, ""))
    assert_equal(1, read("cell", "colspan", :col_span, nil))
    assert_equal(0, read("li", "value", :value, "abc"))
  end

  # [ReflectRange] clamps to the nearer end; colSpan's minimum is 1.
  def test_a_range_clamps_instead_of_falling_back
    assert_equal(1, read("cell", "colspan", :col_span, "0"))
    assert_equal(1000, read("cell", "colspan", :col_span, "3000000000"))
    assert_equal(0, read("cell", "rowspan", :row_span, "0"))
    assert_equal(65_534, read("cell", "rowspan", :row_span, "3000000000"))
  end

  # Without a range, an out-of-range value is treated like an unparseable one.
  def test_without_a_range_an_out_of_range_value_falls_back
    assert_equal(0, read("select", "size", :size, "3000000000"))
    assert_equal(1, read("ol", "start", :start, "3000000000"))
    assert_equal(0, read("li", "value", :value, "3000000000"))
    assert_equal(0, read("video", "width", :width, "3000000000"))
  end

  # A `long` is signed; an `unsigned long` reads a leading "-" as an error.
  def test_only_a_long_accepts_a_negative_value
    assert_equal(-5, read("li", "value", :value, "-5"))
    assert_equal(-5, read("ol", "start", :start, "-5"))
    assert_equal(1, read("cell", "colspan", :col_span, "-5"))
    assert_equal(0, read("select", "size", :size, "-5"))
  end

  # The setter converts out of range to the default BEFORE writing, so the
  # attribute never holds one; WebIDL wraps a negative unsigned long first.
  def test_the_setter_writes_what_the_attribute_is_allowed_to_hold
    cell = @doc.get_element_by_id("cell")
    {5 => "5", 0 => "0", 5000 => "5000", 3_000_000_000 => "1", -1 => "1"}.each do |assigned, stored|
      cell.col_span = assigned

      assert_equal(stored, cell.get_attribute("colspan"), "colSpan = #{assigned}")
    end
  end
end
