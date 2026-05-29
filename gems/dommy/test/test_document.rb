# frozen_string_literal: true

require_relative "test_helper"

class TestDocument < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_body_is_an_element
    assert_kind_of(Dommy::Element, @doc.body)
    assert_equal("BODY", @doc.body.tag_name)
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
