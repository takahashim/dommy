# frozen_string_literal: true

require_relative "test_helper"

# __js_method_names__ is JS-bridge ABI metadata: the set of names a wrapper
# routes through __js_call__ (vs. properties read via __js_get__). These tests
# pin representative names plus the subclass-composition / inheritance behavior.
class TestJsMethodNames < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='foo'><input id='i'><h1>t</h1></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
  end

  def assert_string_array(names)
    assert_kind_of Array, names
    assert(names.all? { |n| n.is_a?(String) }, "expected all names to be Strings, got #{names.inspect}")
  end

  def test_element
    names = @el.__js_method_names__
    assert_string_array(names)
    %w[querySelector appendChild getAttribute addEventListener].each { |m| assert_includes names, m }
  end

  # HTML subclass composes its own methods on top of Element's (super + own).
  def test_html_input_composes_with_element
    names = @doc.get_element_by_id("i").__js_method_names__
    assert_includes names, "select"        # own (HTMLInputElement)
    assert_includes names, "getAttribute"  # inherited (Element)
  end

  # Event subclasses don't override __js_call__, so they inherit Event's names.
  def test_event_subclass_inherits
    names = Dommy::MouseEvent.new("click").__js_method_names__
    %w[preventDefault stopPropagation composedPath].each { |m| assert_includes names, m }
  end

  def test_document
    %w[querySelector createElement getElementById dispatchEvent].each do |m|
      assert_includes @doc.__js_method_names__, m
    end
  end

  def test_window
    %w[setTimeout setInterval fetch addEventListener].each do |m|
      assert_includes @win.__js_method_names__, m
    end
  end

  def test_class_list
    assert_equal %w[add remove contains toggle replace item toString], @el.class_list.__js_method_names__
  end

  def test_style_declaration
    names = @el.__js_get__("style").__js_method_names__
    %w[setProperty removeProperty getPropertyValue item].each { |m| assert_includes names, m }
  end

  # TextNode (CharacterDataNode subclass) adds cloneNode on top of base methods.
  def test_text_node_composes
    names = @doc.create_text_node("x").__js_method_names__
    assert_includes names, "cloneNode"  # own (TextNode)
    assert_includes names, "before"     # inherited (CharacterDataNode)
  end

  def test_node_list
    assert_includes @doc.query_selector_all("div").__js_method_names__, "item"
  end
end
