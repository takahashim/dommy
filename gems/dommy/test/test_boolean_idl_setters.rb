# frozen_string_literal: true

require_relative "test_helper"

# A boolean IDL attribute converts what it is set to with ToBoolean, as a JS
# assignment does: 0, "", NaN, null and undefined are false, anything else
# true — not Ruby's truthiness, under which only nil and false are.
class TestBooleanIdlSetters < Minitest::Test
  FALSY = [0, 0.0, "", Float::NAN, nil, false].freeze

  def setup
    @doc = Dommy.parse("<input id=i><div id=d></div>").document
    @input = @doc.get_element_by_id("i")
  end

  def test_a_reflected_boolean_is_removed_by_a_falsy_value
    FALSY.each do |value|
      @input.__js_set__("disabled", true)
      @input.__js_set__("disabled", value)
      refute @input.has_attribute?("disabled"), value.inspect
    end
    @input.__js_set__("disabled", 1)
    assert @input.has_attribute?("disabled")
  end

  def test_an_enumerated_boolean_writes_its_false_keyword_for_a_falsy_value
    FALSY.each do |value|
      { "draggable" => "false", "spellcheck" => "false", "translate" => "no", "autocorrect" => "off" }.each do |idl, keyword|
        @input.__js_set__(idl, value)
        assert_equal keyword, @input.get_attribute(idl.downcase), "#{idl} = #{value.inspect}"
      end
    end
  end

  # togglePopover((TogglePopoverOptions or boolean) force): a boolean
  # converts with ToBoolean; null picks an empty dictionary, which toggles;
  # a dictionary's force converts when present.
  def test_toggle_popover_converts_its_force
    div = @doc.get_element_by_id("d")
    div.set_attribute("popover", "")
    assert_equal [true, true, false, false], [div.toggle_popover(1), div.toggle_popover(1), div.toggle_popover(0), div.toggle_popover("")]
    assert_equal [true, false], [div.toggle_popover(nil), div.toggle_popover(nil)]
    assert_equal [true, false, true, false],
      [{ "force" => "x" }, { "force" => nil }, {}, { "force" => 0 }].map { |options| div.toggle_popover(options) }
  end
end
