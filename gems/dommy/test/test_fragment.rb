# frozen_string_literal: true

require_relative "test_helper"

class TestFragment < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @frag = @doc.create_document_fragment
  end

  def test_create_returns_fragment
    assert_kind_of(Dommy::Fragment, @frag)
    assert_equal(11, @frag.__js_get__("nodeType"))
  end

  def test_initially_empty
    assert_nil(@frag.first_child)
    assert_nil(@frag.first_element_child)
    assert_equal(0, @frag.child_element_count)
  end

  def test_append_child_adds_node
    el = @doc.create_element("div")
    el.id = "x"
    @frag.append_child(el)
    assert_equal(1, @frag.child_element_count)
    assert_equal("x", @frag.first_element_child.id)
  end

  def test_get_element_by_id_within_fragment
    el = @doc.create_element("section")
    el.id = "s"
    @frag.append_child(el)
    assert_equal("s", @frag.get_element_by_id("s").id)
    assert_nil(@frag.get_element_by_id("absent"))
  end

  def test_query_selector_within_fragment
    el = @doc.create_element("div")
    el.set_attribute("class", "foo")
    @frag.append_child(el)
    refute_nil(@frag.query_selector(".foo"))
    assert_equal(1, @frag.query_selector_all("div").size)
  end
end
