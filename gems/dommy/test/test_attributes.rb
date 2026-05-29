# frozen_string_literal: true

require_relative "test_helper"

class TestAttributes < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<input id='x' type='text' value='foo' disabled>")
    @el = @win.document.get_element_by_id("x")
  end

  def test_get_attribute
    assert_equal("text", @el.get_attribute("type"))
    assert_equal("foo", @el.get_attribute("value"))
  end

  def test_get_attribute_missing_returns_nil
    assert_nil(@el.get_attribute("data-missing"))
  end

  def test_has_attribute
    assert(@el.has_attribute?("type"))
    refute(@el.has_attribute?("nope"))
  end

  def test_set_attribute_round_trip
    @el.set_attribute("placeholder", "Type here")
    assert_equal("Type here", @el.get_attribute("placeholder"))
  end

  def test_remove_attribute
    @el.remove_attribute("disabled")
    refute(@el.has_attribute?("disabled"))
  end

  def test_attribute_names_case_insensitive
    # HTML attribute names normalize to lowercase per spec; round-trip
    # through different cases should hit the same slot.
    @el.set_attribute("Aria-Label", "hi")
    assert_equal("hi", @el.get_attribute("aria-label"))
    assert_equal("hi", @el.get_attribute("ARIA-LABEL"))
  end

  def test_boolean_reflected_disabled
    assert_equal(true, @el[:disabled])
    @el[:disabled] = false
    refute(@el.has_attribute?("disabled"))
    @el[:disabled] = true
    assert(@el.has_attribute?("disabled"))
  end

  def test_value_get_set
    assert_equal("foo", @el[:value])
    @el[:value] = "bar"
    assert_equal("bar", @el[:value])
  end
end
