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
    # Per CSSOM, clearing the last property serializes the declaration back to an
    # EMPTY style attribute — it stays present (removed only via removeAttribute).
    assert(@el.has_attribute?("style"))
    assert_equal("", @el.get_attribute("style"))
  end

  def test_set_property_to_nil_keeps_empty_attribute
    @el.style.css_text = "color:red"
    @el.style.color = nil
    assert(@el.has_attribute?("style"))
    assert_equal("", @el.get_attribute("style"))
  end

  # A CSS property name is ASCII case-insensitive, so the author's spelling in
  # the `style` attribute does not decide how the property can be read.
  def test_a_property_name_is_case_insensitive
    @el.set_attribute("style", "COLOR: red")
    assert_equal("red", @el.style.get_property_value("color"))
    assert_equal("color: red;", @el.style.css_text)
  end

  # ...except a custom property's, which is case-SENSITIVE: `--Foo` and `--foo`
  # are two different properties.
  def test_a_custom_property_name_keeps_its_case
    @el.set_attribute("style", "--Foo: 1px")
    assert_equal("1px", @el.style.get_property_value("--Foo"))
    assert_equal("", @el.style.get_property_value("--foo"))
    assert_equal("--Foo: 1px;", @el.style.css_text)
  end

  # The same rules through the other declaration block the CSSOM exposes, a
  # style rule's — it is the same parser.
  def test_a_style_rule_follows_the_same_name_rules
    @doc.head.inner_html = "<style>#x { COLOR: green; --Bar: 2px }</style>"
    style = @doc.style_sheets.first.css_rules.first.style
    assert_equal("green", style.get_property_value("color"))
    assert_equal("2px", style.get_property_value("--Bar"))
    assert_equal("", style.get_property_value("--bar"))
  end

  # An important declaration outranks a normal one for the same property
  # whatever their order, in either block.
  def test_important_outranks_a_later_normal_declaration
    @el.set_attribute("style", "color: red !important; color: blue")
    assert_equal("red", @el.style.get_property_value("color"))
    assert_equal("important", @el.style.get_property_priority("color"))

    @doc.head.inner_html = "<style>#x { color: red !important; color: blue }</style>"
    style = @doc.style_sheets.first.css_rules.first.style
    assert_equal("red", style.get_property_value("color"))
    assert_equal("important", style.get_property_priority("color"))
  end

  # A declaration whose value cannot be parsed is dropped rather than stored —
  # in a style rule too, which used to keep it.
  def test_an_invalid_value_is_dropped_in_both_blocks
    @el.set_attribute("style", "color:: red; width: 1px")
    assert_equal("", @el.style.get_property_value("color"))
    assert_equal("1px", @el.style.get_property_value("width"))

    @doc.head.inner_html = "<style>#x { color:: red; width: 1px }</style>"
    style = @doc.style_sheets.first.css_rules.first.style
    assert_equal("", style.get_property_value("color"))
    assert_equal("1px", style.get_property_value("width"))
  end
end
