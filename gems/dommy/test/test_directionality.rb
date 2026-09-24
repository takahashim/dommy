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

  def test_an_invalid_dir_is_the_undefined_state_and_inherits
    @doc.body.inner_html = "<div dir='rtl'><span id='a' dir='foo'>x</span><span id='b' dir=' ltr '>x</span></div>"
    %w[a b].each do |id|
      element = @doc.get_element_by_id(id)
      assert element.matches?(":dir(rtl)"), id
      assert_equal "", element.dir, id
    end
  end

  def test_dir_reflects_only_known_values
    element = @doc.create_element("div")
    element.set_attribute("dir", "RTL")
    assert_equal "rtl", element.dir
    element.dir = "sideways"
    assert_equal "", element.dir
    assert_equal "sideways", element.get_attribute("dir")
  end

  def test_dir_means_nothing_on_a_non_html_element
    @doc.body.inner_html = "<div dir='rtl' id='outer'></div>"
    foreign = @doc.create_element_ns("https://example.net/ns", "bogus")
    foreign.set_attribute("dir", "ltr")
    span = @doc.create_element("span")
    foreign.append_child(span)
    @doc.get_element_by_id("outer").append_child(foreign)
    assert span.matches?(":dir(rtl)")
  end

  def test_auto_skips_elements_that_decide_for_themselves
    [
      "<span dir='rtl'>abc</span>x",
      "<bdi>\u05D0</bdi>x",
      "<textarea>\u05D0</textarea>x",
    ].each do |html|
      @doc.body.inner_html = "<div id='x' dir='auto'>#{html}</div>"
      assert @doc.get_element_by_id("x").matches?(":dir(ltr)"), html
    end
    # An invalid dir is the Undefined state, so its text still counts.
    @doc.body.inner_html = "<div id='x' dir='auto'><span dir='foo'>\u05D0</span>x</div>"
    assert @doc.get_element_by_id("x").matches?(":dir(rtl)")
  end

  def test_undefined_tel_input_is_ltr
    @doc.body.inner_html = "<div dir='rtl'><input type='tel' id='tel'><input id='text'></div>"
    assert @doc.get_element_by_id("tel").matches?(":dir(ltr)")
    assert @doc.get_element_by_id("text").matches?(":dir(rtl)")
  end

  def test_auto_on_a_non_textual_input_reads_no_value
    input = @doc.create_element("input")
    input.type = "checkbox"
    input.dir = "auto"
    input.value = HEBREW
    assert input.matches?(":dir(ltr)")
  end

  def test_shadow_tree_inherits_from_the_host
    @doc.body.inner_html = "<div dir='rtl' id='host'></div>"
    shadow = @doc.get_element_by_id("host").attach_shadow("mode" => "open")
    shadow.inner_html = "<span id='inner'>x</span>"
    assert shadow.get_element_by_id("inner").matches?(":dir(rtl)")
  end

  def test_auto_slot_uses_its_assigned_nodes
    @doc.body.inner_html = "<div id='host'>\u05D0</div>"
    shadow = @doc.get_element_by_id("host").attach_shadow("mode" => "open")
    shadow.inner_html = "<slot dir='auto' id='slot'>abc</slot>"
    assert shadow.get_element_by_id("slot").matches?(":dir(rtl)")
  end

  def test_document_dir_without_an_html_element
    document = @doc.implementation.create_document(nil, "root", nil)
    document.dir = "rtl"
    assert_equal "", document.dir
    assert_nil document.document_element.get_attribute("dir")
  end
end
