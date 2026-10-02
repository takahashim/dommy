# frozen_string_literal: true

require "json"
require_relative "test_helper"

# ARIAMixin (WAI-ARIA §10.1): `role`, the aria* strings and the element
# references Element reflects.
class TestAriaReflection < Minitest::Test
  include DommyTestHelper

  ARIA = Dommy::Internal::ElementAria

  def setup
    @doc = make_window("<div id=host><p id=p></p><i id=t></i><b id=u></b></div>").document
    @p = @doc.get_element_by_id("p")
    @t = @doc.get_element_by_id("t")
    @u = @doc.get_element_by_id("u")
  end

  # The tables are the IDL's own: every ARIAMixin attribute, reflecting the
  # content attribute the IDL names.
  def test_the_tables_are_the_idl_mixin
    idl = JSON.parse(File.read(File.join(__dir__, "fixtures/webidl/interfaces.json")))
    members = idl["interfaces"]["Element"]["members"].select { |m| m["mixin"] == "ARIAMixin" }
    expected = members.to_h { |m| [m["name"], m.dig("reflect", "attr") || m["name"]] }

    assert_equal expected, ARIA::STRING_ATTRIBUTES.merge(ARIA::ELEMENT_ATTRIBUTES, ARIA::ELEMENTS_ATTRIBUTES)
  end

  # A name the IDL does not define is an expando, not a reflection.
  def test_other_aria_names_are_no_reflections
    %w[ariaFoo ariaLabelledBy ariaActiveDescendant ariaErrorMessageElement ariaFooElements].each do |name|
      assert_equal Dommy::Bridge::ABSENT, @p.__js_get__(name), name
      assert_equal Dommy::Bridge::UNHANDLED, @p.__js_set__(name, "x"), name
    end
    assert_equal [], @p.attributes.map(&:name).grep(/\Aaria-/)
  end
end
