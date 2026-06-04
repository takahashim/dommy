# frozen_string_literal: true

require_relative "test_helper"

class TestStyle < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @el = @doc.create_element("div")
  end

  def test_css_text_empty_initially
    assert_equal("", @el.style.css_text)
  end

  def test_css_text_set_parses_entries
    @el.style.css_text = "color: red; background-color: blue;"
    assert_equal("red", @el.style["color"])
    assert_equal("blue", @el.style["background-color"])
  end

  def test_camel_case_setter_writes_kebab_property
    @el.style.background_color = "green"
    assert_equal("background-color: green;", @el.get_attribute("style"))
  end

  def test_camel_case_getter_reads_kebab_property
    @el.set_attribute("style", "background-color:purple;color:red;")
    assert_equal("purple", @el.style.background_color)
    assert_equal("red", @el.style.color)
  end

  def test_length_reflects_property_count
    @el.style.css_text = "a:1;b:2;c:3"
    assert_equal(3, @el.style.length)
  end

  def test_index_returns_property_name
    @el.style.css_text = "color:red;background-color:blue"
    assert_equal("color", @el.style[0])
    assert_equal("background-color", @el.style[1])
  end

  def test_iterable_yields_property_names
    @el.style.css_text = "a:1;b:2"
    assert_equal(["a", "b"], @el.style.to_a)
  end

  def test_set_property_via_js_call
    @el.style.__js_call__("setProperty", ["color", "red"])
    assert_equal("color: red;", @el.get_attribute("style"))
  end

  def test_remove_property_via_js_call
    @el.style.css_text = "color:red"
    @el.style.__js_call__("removeProperty", ["color"])
    refute(@el.has_attribute?("style"))
  end

  def test_set_property_to_nil_removes
    @el.style.css_text = "color:red"
    @el.style.color = nil
    refute(@el.has_attribute?("style"))
  end
end
