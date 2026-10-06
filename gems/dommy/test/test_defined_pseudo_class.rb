# frozen_string_literal: true

require_relative "test_helper"

# `:defined` matches an element whose custom element state is "uncustomized"
# or "custom": every element but an HTML one with a valid custom element name
# that its registry has not (yet) constructed.
class TestDefinedPseudoClass < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div></div><a-a></a-a><font-face></font-face><svg><a-a></a-a></svg>")
    @doc = @win.document
  end

  def defined_el?(selector) = @doc.query_selector(selector).matches?(":defined")

  def test_uncustomized_elements_are_defined
    assert defined_el?("div")
    assert defined_el?("font-face"), "a reserved name is not a valid custom element name"
    assert @doc.query_selector("svg a-a").matches?(":defined"), "only HTML elements can be custom"
  end

  def test_an_undefined_custom_element_is_not_defined_until_its_definition_arrives
    refute defined_el?("body > a-a")
    assert_equal 1, @doc.query_selector_all(":not(:defined)").length
    @win.custom_elements.define("a-a", Class.new(Dommy::HTMLElement))
    assert defined_el?("body > a-a")
    assert @doc.create_element("a-a").matches?(":defined")
  end

  def test_a_document_without_a_browsing_context_has_no_definitions
    @win.custom_elements.define("a-a", Class.new(Dommy::HTMLElement))
    doc = @doc.implementation.create_html_document("")
    refute doc.create_element("a-a").matches?(":defined")
  end
end
