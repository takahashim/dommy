# frozen_string_literal: true

require_relative "test_helper"

class TestDocumentExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<header><h1>Title</h1></header><main><p name='msg'>hi</p></main>")
    @doc = @win.document
  end

  def test_head_returns_head_element
    head = @doc.head
    refute_nil(head)
    assert_equal("HEAD", head.tag_name)
  end

  def test_doctype_returns_html_doctype
    dt = @doc.doctype
    refute_nil(dt)
    assert_equal("html", dt.__js_get__("name"))
    assert_equal(10, dt.__js_get__("nodeType"))
  end

  def test_cookie_round_trip
    @doc.cookie = "session=abc"
    @doc.cookie = "theme=dark; Path=/; Expires=Wed"
    assert_equal("session=abc; theme=dark", @doc.cookie)
  end

  def test_cookie_initially_empty
    assert_equal("", @doc.cookie)
  end

  def test_create_element_ns
    el = @doc.create_element_ns("http://www.w3.org/2000/svg", "svg")
    refute_nil(el)
    assert_equal("SVG", el.tag_name)
  end

  def test_get_elements_by_tag_name
    h1s = @doc.get_elements_by_tag_name("h1")
    assert_equal(1, h1s.size)
    assert_equal("H1", h1s.first.tag_name)
  end

  def test_get_elements_by_tag_name_star
    all = @doc.get_elements_by_tag_name("*")
    assert_operator(all.size, :>=, 4)
  end

  def test_get_elements_by_name
    list = @doc.get_elements_by_name("msg")
    assert_equal(1, list.size)
    assert_equal("P", list.first.tag_name)
  end

  def test_write_appends_to_body
    before = @doc.body.children.size
    @doc.write("<div id='written'>w</div>")
    assert_equal(before + 1, @doc.body.children.size)
    assert_equal("written", @doc.body.children[-1].id)
  end

  def test_open_close_are_noop
    assert_nil(@doc.open)
    assert_nil(@doc.close)
  end

  def test_node_type_constant
    assert_equal(9, @doc.__js_get__("nodeType"))
  end
end
