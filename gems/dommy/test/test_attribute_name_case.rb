# frozen_string_literal: true

require_relative "test_helper"

# On an HTML element in an HTML document, attribute names are matched and
# stored in ASCII lowercase (DOM "get an attribute by name", setAttribute):
# only A-Z fold, so `\u00c4` and `\u00e4` are different attributes.
class TestAttributeNameCase < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window("<p id=x \u00c4>x</p>").document
    @x = @doc.get_element_by_id("x")
  end

  def test_set_attribute_folds_ascii_only
    @x.set_attribute("DATA-A", "1")
    @x.set_attribute("\u00d6", "2")
    assert_equal ["id", "\u00c4", "data-a", "\u00d6"], @x.get_attribute_names
  end

  def test_a_non_ascii_capital_is_not_its_lowercase
    assert @x.has_attribute?("\u00c4")
    refute @x.has_attribute?("\u00e4")
  end

  def test_an_attribute_selector_matches_a_non_ascii_name_as_written
    assert @x.matches?("[\u00c4]")
    refute @x.matches?("[\u00e4]")
  end
end
