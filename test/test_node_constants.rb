# frozen_string_literal: true

require_relative "test_helper"

class TestNodeConstants < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x'>hello</div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
  end

  def test_element_node_constant
    assert_equal(1, Dommy::Element::ELEMENT_NODE)
    assert_equal(1, @el.class::ELEMENT_NODE)
  end

  def test_text_node_constant
    assert_equal(3, Dommy::Element::TEXT_NODE)
  end

  def test_comment_node_constant
    assert_equal(8, Dommy::Element::COMMENT_NODE)
  end

  def test_document_fragment_node_constant
    assert_equal(11, Dommy::Element::DOCUMENT_FRAGMENT_NODE)
  end

  def test_node_type_value_matches_element
    assert_equal(1, @el.__js_get__("nodeType"))
  end

  def test_node_type_value_matches_text
    text = @doc.create_text_node("hi")
    assert_equal(3, text.__js_get__("nodeType"))
  end

  def test_node_type_value_matches_comment
    c = @doc.create_comment("hi")
    assert_equal(8, c.__js_get__("nodeType"))
  end

  def test_node_type_value_matches_fragment
    f = @doc.create_document_fragment
    assert_equal(11, f.__js_get__("nodeType"))
  end
end
