# frozen_string_literal: true

require_relative "test_helper"

# valueAsDate applies to date, month, week and time; a datetime-local value has
# no time zone, so it does not. From Ruby the Date is a UTC ::Time.
class TestInputValueAsDate < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window("<input id='i'>").document
    @input = @doc.get_element_by_id("i")
  end

  def input(type, value = nil)
    @input.type = type
    @input.value = value if value
    @input
  end

  def test_getter_reads_each_type_as_utc_midnight_or_time_of_day
    assert_equal Time.utc(2019, 12, 10), input("date", "2019-12-10").value_as_date
    assert_equal Time.utc(2019, 12, 1), input("month", "2019-12").value_as_date
    assert_equal Time.utc(2019, 12, 9), input("week", "2019-W50").value_as_date
    assert_equal Time.utc(1970, 1, 1, 12, 34, 56.789r), input("time", "12:34:56.789").value_as_date
  end

  def test_getter_is_nil_for_an_invalid_value_or_an_inapplicable_type
    assert_nil input("date", "2019-02-29").value_as_date
    assert_nil input("month", "2019-00").value_as_date
    assert_nil input("datetime-local", "2019-12-10T00:00").value_as_date
    assert_nil input("text", "2019-12-10").value_as_date
  end

  def test_setter_writes_the_utc_component_for_the_type
    input("date").value_as_date = Time.utc(2016, 2, 29, 23, 0)
    assert_equal "2016-02-29", @input.value
    input("month").value_as_date = Time.utc(2019, 12, 31)
    assert_equal "2019-12", @input.value
    input("week").value_as_date = Time.utc(2019, 12, 12)
    assert_equal "2019-W50", @input.value
    input("time").value_as_date = Time.utc(2001, 1, 1, 23, 59)
    assert_equal "23:59", @input.value
    input("date").value_as_date = Date.new(2020, 1, 2)
    assert_equal "2020-01-02", @input.value
  end

  def test_setter_clears_on_nil_and_an_invalid_js_date
    input("date", "2019-12-10").value_as_date = nil
    assert_equal "", @input.value
    input("date", "2019-12-10").value_as_date = Dommy::Bridge::Date.new(1, Float::NAN)
    assert_equal "", @input.value
  end

  def test_setter_errors_follow_the_idl_order
    # A primitive fails the `object?` conversion before applicability.
    assert_raises(Dommy::Bridge::TypeError) { input("checkbox").value_as_date = 5 }
    assert_raises(Dommy::DOMException::InvalidStateError) { input("datetime-local").value_as_date = Time.now }
    assert_raises(Dommy::Bridge::TypeError) { input("date").value_as_date = {} }
  end

  def test_value_as_number_setter_converts_like_js
    input("number").value_as_number = " 12 "
    assert_equal "12", @input.value
    @input.value_as_number = :NaN
    assert_equal "", @input.value
    assert_raises(Dommy::Bridge::TypeError) { @input.value_as_number = Float::INFINITY }
    # Infinity is a TypeError even where valueAsNumber does not apply.
    assert_raises(Dommy::Bridge::TypeError) { input("checkbox").value_as_number = -Float::INFINITY }
    assert_raises(Dommy::DOMException::InvalidStateError) { @input.value_as_number = 1 }
  end
end
