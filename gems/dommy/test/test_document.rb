# frozen_string_literal: true

require_relative "test_helper"

class TestDocument < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_current_script_defaults_to_nil_and_tracks_set
    assert_nil @doc.__js_get__("currentScript")

    script = @doc.create_element("script")
    @doc.__internal_set_current_script__(script)
    assert_same script, @doc.__js_get__("currentScript")

    @doc.__internal_set_current_script__(nil)
    assert_nil @doc.__js_get__("currentScript")
  end

  def test_body_is_an_element
    assert_kind_of(Dommy::Element, @doc.body)
    assert_equal("BODY", @doc.body.tag_name)
  end

  # A fully-parsed, foreground document: ready and visible. Libraries gate work
  # on these (Turbo's preloader on readyState, nextRepaint on visibilityState).
  def test_ready_and_visibility_state
    assert_equal("complete", @doc.__js_get__("readyState"))
    assert_equal("visible", @doc.__js_get__("visibilityState"))
    assert_equal(false, @doc.__js_get__("hidden"))
  end

  def test_location_is_window_location
    assert_same(@win.__js_get__("location"), @doc.__js_get__("location"))
  end

  def test_character_set
    assert_equal("UTF-8", @doc.__js_get__("characterSet"))
    assert_equal("UTF-8", @doc.__js_get__("charset"))
    assert_equal("UTF-8", @doc.__js_get__("inputEncoding"))
  end

  def test_dir_reflects_html_attribute
    assert_equal("", @doc.__js_get__("dir"))
    @doc.__js_set__("dir", "rtl")
    assert_equal("rtl", @doc.__js_get__("dir"))
    assert_equal("rtl", @doc.document_element.get_attribute("dir"))
  end

  def test_design_mode_enum
    assert_equal("off", @doc.__js_get__("designMode"))
    @doc.__js_set__("designMode", "on")
    assert_equal("on", @doc.__js_get__("designMode"))
    @doc.__js_set__("designMode", "garbage")
    assert_equal("on", @doc.__js_get__("designMode")) # invalid ignored
  end

  def test_extra_collections_present
    %w[embeds plugins anchors styleSheets].each do |name|
      coll = @doc.__js_get__(name)
      refute_nil(coll, name)
      assert_equal(0, coll.length, name)
    end
  end

  def test_first_last_child_and_root_node_links
    assert_kind_of(Dommy::Element, @doc.__js_get__("firstChild"))
    assert_kind_of(Dommy::Element, @doc.__js_get__("lastChild"))
    assert_nil(@doc.__js_get__("parentNode"))
    assert_nil(@doc.__js_get__("ownerDocument"))
  end

  def test_parent_node_mutation_methods
    comment = @doc.__js_call__("createComment", ["x"])
    @doc.__js_call__("append", [comment])
    assert_equal(8, @doc.__js_get__("lastChild").__js_get__("nodeType"))

    @doc.__js_call__("removeChild", [comment])
    assert_equal("HTML", @doc.__js_get__("lastChild").tag_name)
  end

  def test_insert_before_and_replace_child
    c1 = @doc.__js_call__("createComment", ["a"])
    @doc.__js_call__("insertBefore", [c1, @doc.document_element])
    assert_same(c1, @doc.__js_get__("firstChild"))

    c2 = @doc.__js_call__("createComment", ["b"])
    @doc.__js_call__("replaceChild", [c2, c1])
    assert_same(c2, @doc.__js_get__("firstChild"))
  end

  def test_remove_child_doctype
    refute_nil(@doc.__js_get__("doctype"))
    @doc.__js_call__("removeChild", [@doc.__js_get__("doctype")])
    assert_nil(@doc.__js_get__("doctype"))
  end

  def test_clone_node_deep
    @doc.body.inner_html = "<p id='x'>hello</p>"
    copy = @doc.__js_call__("cloneNode", [true])
    assert_kind_of(Dommy::Document, copy)
    refute_same(@doc, copy)
    assert_equal("hello", copy.query_selector("#x").text_content)
  end

  def test_document_element_is_html
    el = @doc.document_element
    refute_nil(el)
    assert_equal("HTML", el.tag_name)
  end

  def test_default_view_is_the_owning_window
    assert_same(@win, @doc.default_view)
  end

  def test_title_get_set_round_trip
    @doc.title = "Page Title"
    assert_equal("Page Title", @doc.title)
  end

  def test_title_empty_when_unset
    assert_equal("", @doc.title)
  end

  def test_create_element_returns_an_element_with_given_tag
    el = @doc.create_element("p")
    assert_kind_of(Dommy::Element, el)
    assert_equal("P", el.tag_name)
  end

  def test_create_text_node
    node = @doc.create_text_node("hello")
    assert_equal("hello", node.__js_get__("textContent"))
  end

  def test_query_selector_finds_by_class
    @doc.body.inner_html = "<div class='a'></div><div class='b'></div>"
    el = @doc.query_selector(".b")
    refute_nil(el)
    assert_equal("B", el.class_name.upcase)
  end

  def test_query_selector_all_returns_array
    @doc.body.inner_html = "<p></p><p></p><p></p>"
    list = @doc.query_selector_all("p")
    assert_kind_of(Array, list)
    assert_equal(3, list.size)
  end

  def test_query_selector_all_empty_returns_empty
    assert_equal([], @doc.query_selector_all("nothing"))
  end

  def test_get_element_by_id
    @doc.body.inner_html = "<span id='target'>hi</span>"
    assert_equal("hi", @doc.get_element_by_id("target").text_content)
    assert_nil(@doc.get_element_by_id("nope"))
  end
end
