# frozen_string_literal: true

require_relative "test_helper"

# HTML's dir attribute: the computed directionality (`:dir()` and
# `getComputedStyle().direction`), `document.dir`, and the dir=auto heuristic.
# Mirrors WPT html/dom/elements/global-attributes/dir-assorted.window.js and
# document-dir.html.
class TestDirectionality < Minitest::Test
  include DommyTestHelper

  HEBREW = "\u05D0\u05D1"

  def setup
    @win = make_window("<p>hi</p>")
    @doc = @win.document
  end

  def test_root_and_detached_default_to_ltr
    assert @doc.document_element.matches?(":dir(ltr)")
    assert @doc.create_element("foobar").matches?(":dir(ltr)")
    assert @doc.create_element("foobar").matches?(":dir(rtl)") == false
  end

  def test_direction_inherits_from_the_parent_element
    parent = @doc.create_element("foobar")
    child = @doc.create_element("foobar")
    parent.dir = "rtl"
    parent.append_child(child)
    assert child.matches?(":dir(rtl)")
    parent.dir = "ltr"
    assert child.matches?(":dir(ltr)")
  end

  def test_direction_inherits_through_a_non_html_element
    parent = @doc.create_element("div")
    child = @doc.create_element_ns("foobar", "foobar")
    parent.dir = "rtl"
    parent.append_child(child)
    assert child.matches?(":dir(rtl)")
  end

  def test_insertion_and_removal_change_inheritance
    container = @doc.create_element("div")
    container.dir = "rtl"
    element = @doc.create_element("div")
    assert element.matches?(":dir(ltr)")
    container.append_child(element)
    assert element.matches?(":dir(rtl)")
    element.remove
    assert element.matches?(":dir(ltr)")
  end

  def test_auto_uses_the_first_strong_character
    element = @doc.create_element("div")
    element.dir = "auto"
    text = @doc.create_text_node(HEBREW)
    element.append_child(text)
    assert element.matches?(":dir(rtl)")
    text.data = "ABC"
    assert element.matches?(":dir(ltr)")
  end

  def test_auto_ignores_script_and_style_text
    %w[script style].each do |tag|
      element = @doc.create_element("div")
      element.dir = "auto"
      inner = @doc.create_element(tag)
      inner.append_child(@doc.create_text_node(HEBREW))
      element.append_child(inner)
      assert element.matches?(":dir(ltr)"), tag
    end
  end

  def test_bdi_defaults_to_auto
    bdi = @doc.create_element("bdi")
    bdi.append_child(@doc.create_text_node(HEBREW))
    assert bdi.matches?(":dir(rtl)")
  end

  def test_input_dir_auto_uses_its_value
    input = @doc.create_element("input")
    input.dir = "auto"
    input.value = HEBREW
    assert input.matches?(":dir(rtl)")
  end

  def test_computed_style_direction
    @doc.body.inner_html = "<div dir='rtl' id='x'>hi</div>"
    element = @doc.get_element_by_id("x")
    assert_equal "rtl", @win.get_computed_style(element).get_property_value("direction")
    assert_equal "ltr", @win.get_computed_style(@doc.body).get_property_value("direction")
  end

  def test_document_dir_reflects_the_document_element
    window = Dommy.parse("<html dir=LTR><body></body></html>")
    document = window.document
    assert_equal "ltr", document.dir

    document.dir = "x-garbage"
    assert_equal "", document.dir
    assert_equal "x-garbage", document.document_element.get_attribute("dir")

    document.dir = ""
    assert_equal "", document.dir
    assert document.document_element.has_attribute?("dir")
  end
end
