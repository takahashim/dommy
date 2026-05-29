# frozen_string_literal: true

require_relative "test_helper"

class TestInsertAdjacent < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'><p id='target'>middle</p></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @target = @doc.get_element_by_id("target")
  end

  def test_insert_adjacent_element_beforebegin
    el = @doc.create_element("span")
    el.text_content = "B"
    @target.insert_adjacent_element("beforebegin", el)
    assert_equal("SPAN", @root.children[0].tag_name)
    assert_equal("P", @root.children[1].tag_name)
  end

  def test_insert_adjacent_element_afterbegin
    el = @doc.create_element("em")
    el.text_content = "x"
    @target.insert_adjacent_element("afterbegin", el)
    assert_equal("EM", @target.children[0].tag_name)
  end

  def test_insert_adjacent_element_beforeend
    el = @doc.create_element("em")
    el.text_content = "x"
    @target.insert_adjacent_element("beforeend", el)
    assert_equal("EM", @target.children[-1].tag_name)
  end

  def test_insert_adjacent_element_afterend
    el = @doc.create_element("span")
    el.text_content = "A"
    @target.insert_adjacent_element("afterend", el)
    assert_equal("P", @root.children[0].tag_name)
    assert_equal("SPAN", @root.children[1].tag_name)
  end

  def test_insert_adjacent_html_beforeend
    @target.insert_adjacent_html("beforeend", "<b>bold</b><i>italic</i>")
    assert_equal(2, @target.child_element_count)
  end

  def test_insert_adjacent_html_afterbegin
    @target.insert_adjacent_html("afterbegin", "<a>link</a>")
    assert_equal("A", @target.children[0].tag_name)
  end

  def test_insert_adjacent_text_appends_text
    @target.insert_adjacent_text("beforeend", " extra")
    assert_equal("middle extra", @target.text_content)
  end

  def test_insert_adjacent_element_on_unparented_returns_nil
    detached = @doc.create_element("p")
    assert_nil(detached.insert_adjacent_element("beforebegin", @doc.create_element("span")))
    assert_nil(detached.insert_adjacent_element("afterend", @doc.create_element("span")))
  end

  def test_to_s_returns_outer_html
    s = @target.to_s
    assert_match(/<p[^>]*id=.target.[^>]*>middle<\/p>/, s)
  end

  def test_get_elements_by_tag_name_on_element
    items = @root.get_elements_by_tag_name("p")
    assert_equal(1, items.size)
  end
end
