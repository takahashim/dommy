# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Element.insertAdjacentElement and
# insertAdjacentText. (insertAdjacentHTML has partial coverage in
# test/wpt/test_wpt_dom_parsing.rb.)
#
# WPT: dom/nodes/Element-insertAdjacentElement.html,
#      dom/nodes/Element-insertAdjacentText.html
# Spec: https://dom.spec.whatwg.org/#dom-element-insertadjacentelement
#
# Four position keywords are accepted:
#   beforebegin -> as a previous sibling of target
#   afterbegin  -> as target's first child
#   beforeend   -> as target's last child
#   afterend    -> as a next sibling of target
class TestWPTInsertAdjacentElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @target = @doc.create_element("div")
    @target.set_attribute("id", "target")
    @doc.body.append_child(@target)
    @target.append_child(@doc.create_element("span")) # existing child
  end

  def test_beforebegin_inserts_as_previous_sibling
    new_el = @doc.create_element("p")
    @target.insert_adjacent_element("beforebegin", new_el)
    assert_same(new_el, @target.previous_sibling)
  end

  def test_afterbegin_inserts_as_first_child
    new_el = @doc.create_element("p")
    @target.insert_adjacent_element("afterbegin", new_el)
    assert_same(new_el, @target.first_child)
  end

  def test_beforeend_inserts_as_last_child
    new_el = @doc.create_element("p")
    @target.insert_adjacent_element("beforeend", new_el)
    assert_same(new_el, @target.last_child)
  end

  def test_afterend_inserts_as_next_sibling
    new_el = @doc.create_element("p")
    @target.insert_adjacent_element("afterend", new_el)
    assert_same(new_el, @target.next_sibling)
  end
end

class TestWPTInsertAdjacentText < Minitest::Test
  # Spec: insertAdjacentText accepts the same position keywords as
  # insertAdjacentElement, but the second argument is a string that
  # is wrapped into a freshly-created Text node.

  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @target = @doc.create_element("div")
    @doc.body.append_child(@target)
  end

  def test_afterbegin_inserts_text_node
    @target.insert_adjacent_text("afterbegin", "hello")
    assert_kind_of(Dommy::TextNode, @target.first_child)
    assert_equal("hello", @target.first_child.text_content)
  end

  def test_beforeend_appends_text
    @target.append_child(@doc.create_element("span"))
    @target.insert_adjacent_text("beforeend", "tail")
    assert_equal("tail", @target.last_child.text_content)
  end

  def test_beforebegin_inserts_text_as_sibling
    @target.insert_adjacent_text("beforebegin", "head-sibling")
    assert_equal("head-sibling", @target.previous_sibling.text_content)
  end

  def test_afterend_inserts_text_as_next_sibling
    @target.insert_adjacent_text("afterend", "tail-sibling")
    assert_equal("tail-sibling", @target.next_sibling.text_content)
  end
end
