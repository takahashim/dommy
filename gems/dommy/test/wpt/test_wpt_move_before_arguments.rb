# frozen_string_literal: true

require_relative "../test_helper"

# moveBefore(node, child) converts both arguments before any step: `node` is a
# Node, `child` a Node or null / undefined, and anything else is a TypeError
# rather than whatever the move steps would make of it. And a doctype answers
# isConnected like any other node. Chrome 149 and Firefox 155 agree.
#
# WPT: dom/nodes/moveBefore/Node-moveBefore.html
class TestWPTMoveBeforeArguments < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<!DOCTYPE html><p id='p'>text</p>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
  end

  def test_a_child_that_is_not_a_node_is_a_type_error
    text = @p.first_child
    assert_raises(Dommy::Bridge::TypeError) { @doc.body.move_before(text, { "a" => "b" }) }
    assert_raises(Dommy::Bridge::TypeError) { @doc.body.__js_call__("moveBefore", [text, "x"]) }
    assert_equal("text", @p.first_child.data)
  end

  def test_null_and_undefined_children_append
    text = @p.first_child
    @doc.body.__js_call__("moveBefore", [text, Dommy::Bridge::UNDEFINED])
    assert_same(text, @doc.body.last_child)
  end

  def test_the_document_converts_its_arguments_too
    assert_raises(Dommy::Bridge::TypeError) { @doc.move_before(nil, nil) }
    assert_raises(Dommy::Bridge::TypeError) { @doc.move_before(@doc.document_element, { "a" => "b" }) }
  end

  def test_a_doctype_answers_is_connected
    assert_equal(true, @doc.doctype.__js_get__("isConnected"))
    assert_equal(false, @doc.implementation.create_document_type("x", "", "").__js_get__("isConnected"))
  end
end
