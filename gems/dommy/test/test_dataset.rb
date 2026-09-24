# frozen_string_literal: true

require_relative "test_helper"

# `element.dataset` (DOMStringMap): reading / writing the data-* attributes of
# parsed markup, the camelCase <-> data-* round trip, the name validation the
# setter and deleter do, and the HTML / SVG / MathML scope.
# Mirrors WPT html/dom/elements/global-attributes/dataset-*.html.
class TestDataset < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' data-role='primary' data-user-id='42'></div>")
    @el = @win.document.get_element_by_id("x")
    @ds = @el.dataset
  end

  def test_read_simple_key
    assert_equal("primary", @ds.__js_get__("role"))
  end

  def test_read_camelcase_maps_to_kebab_attribute
    assert_equal("42", @ds.__js_get__("userId"))
  end

  def test_missing_property_is_absent
    # A missing data-* reads as JS `undefined` (ABSENT), not null.
    assert_equal(Dommy::Bridge::ABSENT, @ds.__js_get__("missing"))
  end

  def test_set_writes_attribute_with_kebab
    @ds.__js_set__("status", "active")
    assert_equal("active", @el.get_attribute("data-status"))
  end

  def test_set_camelcase_kebabs_at_attribute_level
    @ds.__js_set__("itemCount", "7")
    assert_equal("7", @el.get_attribute("data-item-count"))
  end

  # set a key, then read the attribute the spec says it maps to
  def assert_round_trip(key, attribute)
    @ds.__js_set__(key, "value")
    assert_equal "value", @el.get_attribute(attribute), "#{key.inspect} -> #{attribute.inspect}"
    assert_equal "value", @ds.__js_get__(key)
  end

  def test_name_round_trip
    assert_round_trip "foo", "data-foo"
    assert_round_trip "fooBar", "data-foo-bar"
    assert_round_trip "-", "data--"
    assert_round_trip "Foo", "data--foo"
    assert_round_trip "-Foo", "data---foo"
    assert_round_trip "", "data-"
    assert_round_trip "\u00E0", "data-\u00E0"
    assert_round_trip "\u037Efoo", "data-\u037Efoo"
    assert_round_trip "toString", "data-to-string"
  end

  def test_lowercased_attribute_names_read_back
    # setAttribute lowercases on an HTML element, so data-Foo reads as "foo".
    @el.set_attribute("data-Foo", "value")
    assert_equal "value", @ds.__js_get__("foo")
  end

  def test_setter_rejects_unround_trippable_names
    assert_raises(Dommy::DOMException::SyntaxError) { @ds.__js_set__("-foo", "x") }
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @ds.__js_set__("foo ", "x") }
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @ds.__js_set__("a=b", "x") }
  end

  # A valid attribute local name forbids only whitespace, NULL, "/", "=" and ">".
  def test_setter_accepts_any_other_attribute_name_characters
    @ds.__js_set__("a<b\"c'd&e", "x")
    assert_equal "x", @el.get_attribute("data-a<b\"c'd&e")
  end

  def test_named_getter_does_not_shadow_a_hyphen_name
    @el.set_attribute("data--foo", "value")
    assert_same Dommy::Bridge::ABSENT, @ds.__js_get__("-foo")
    assert_includes @ds.__js_named_props__, "Foo"
  end

  def test_deleting_a_hyphen_name_is_a_no_op
    @el.set_attribute("data--foo", "value")
    @ds.__js_delete__("-foo")
    assert @el.has_attribute?("data--foo")
  end

  def test_deleter_removes_the_attribute
    @el.set_attribute("data-foo-bar", "value")
    @ds.__js_delete__("fooBar")
    refute @el.has_attribute?("data-foo-bar")
  end

  def test_scope_is_html_svg_mathml
    document = @win.document
    assert_kind_of Dommy::DatasetMap, @el.__js_get__("dataset")
    svg = document.create_element_ns("http://www.w3.org/2000/svg", "svg")
    assert_kind_of Dommy::DatasetMap, svg.__js_get__("dataset")
    mathml = document.create_element_ns("http://www.w3.org/1998/Math/MathML", "math")
    assert_kind_of Dommy::DatasetMap, mathml.__js_get__("dataset")
    random = document.create_element_ns("test", "test")
    assert_same Dommy::Bridge::ABSENT, random.__js_get__("dataset")
  end

  def test_attribute_named_datafoo_is_not_in_the_dataset
    el = @win.document.create_element("div")
    el.set_attribute("dataFoo", "value")
    assert_equal 0, el.dataset.__js_named_props__.length
  end
end