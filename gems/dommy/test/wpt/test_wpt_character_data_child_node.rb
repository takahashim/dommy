# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the ChildNode mixin on TextNode / CommentNode:
# .before(...), .after(...), .replaceWith(...). The WPT defines these
# on all ChildNodes; Dommy's CharacterDataNode previously only had
# remove(), leaving this gap.
#
# WPT: dom/nodes/ChildNode-before.html,
#      dom/nodes/ChildNode-after.html,
#      dom/nodes/ChildNode-replaceWith.html
# Spec: https://dom.spec.whatwg.org/#interface-childnode
#
# Tests cover the happy path with element arguments and the string
# convenience form (string -> TextNode coercion). MutationObserver
# notification is verified in test_wpt_mutation_observer.rb (this
# file's regression tests live there too).
class TestWPTCharacterDataBefore < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @text = @doc.create_text_node("middle")
    @parent.append_child(@text)
  end

  def test_before_inserts_element_in_front_of_text
    new_el = @doc.create_element("span")
    @text.before(new_el)
    assert_equal(2, @parent.child_nodes.length)
    assert_equal("SPAN", @parent.child_nodes[0].tag_name)
    assert_kind_of(Dommy::TextNode, @parent.child_nodes[1])
  end

  def test_before_with_string_inserts_text_node
    @text.before("prefix")
    assert_kind_of(Dommy::TextNode, @parent.first_child)
    assert_equal("prefix", @parent.first_child.text_content)
  end

  def test_before_is_noop_when_detached
    detached = @doc.create_text_node("orphan")
    # No parent: before() returns nil and does nothing observable.
    result = detached.before(@doc.create_element("span"))
    assert_nil(result)
  end
end

class TestWPTCharacterDataAfter < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @text = @doc.create_text_node("middle")
    @parent.append_child(@text)
  end

  def test_after_appends_element_when_text_is_last
    new_el = @doc.create_element("span")
    @text.after(new_el)
    assert_equal(2, @parent.child_nodes.length)
    assert_kind_of(Dommy::TextNode, @parent.child_nodes[0])
    assert_equal("SPAN", @parent.child_nodes[1].tag_name)
  end

  def test_after_inserts_before_next_sibling
    existing_next = @doc.create_element("p")
    @parent.append_child(existing_next)
    new_el = @doc.create_element("span")
    @text.after(new_el)
    # Order: text, new_el (SPAN), existing_next (P)
    assert_equal(["#text", "SPAN", "P"],
                 @parent.child_nodes.map { |n| n.respond_to?(:tag_name) ? n.tag_name : "#text" })
  end

  def test_after_with_string_inserts_text_node
    # `after("suffix")` inserts a Text node after @text. Backends differ on
    # adjacent-text coalescing: Nokogiri auto-merges "middle" + "suffix" into a
    # single text node, while Makiri keeps them separate (spec-correct — only
    # normalize() merges). Assert the combined content, which holds either way.
    @text.after("suffix")
    assert_equal("middlesuffix", @parent.text_content)
    assert(@parent.child_nodes.all? { |n| n.is_a?(Dommy::TextNode) })
  end

  def test_after_is_noop_when_detached
    detached = @doc.create_text_node("orphan")
    assert_nil(detached.after(@doc.create_element("span")))
  end
end

class TestWPTCharacterDataReplaceWith < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @text = @doc.create_text_node("middle")
    @parent.append_child(@text)
  end

  def test_replace_with_element_swaps_in_new_node
    new_el = @doc.create_element("span")
    @text.replace_with(new_el)
    assert_equal(1, @parent.child_nodes.length)
    assert_equal("SPAN", @parent.child_nodes[0].tag_name)
  end

  def test_replace_with_string_swaps_in_text_node
    @text.replace_with("replaced")
    assert_equal(1, @parent.child_nodes.length)
    assert_equal("replaced", @parent.first_child.text_content)
  end

  def test_replace_with_is_noop_when_detached
    detached = @doc.create_text_node("orphan")
    assert_nil(detached.replace_with(@doc.create_element("span")))
  end
end

class TestWPTCharacterDataJSBridge < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @text = @doc.create_text_node("middle")
    @parent.append_child(@text)
  end

  def test_js_bridge_before
    new_el = @doc.create_element("span")
    @text.__js_call__("before", [new_el])
    assert_equal("SPAN", @parent.child_nodes[0].tag_name)
  end

  def test_js_bridge_after
    new_el = @doc.create_element("span")
    @text.__js_call__("after", [new_el])
    assert_equal("SPAN", @parent.child_nodes[1].tag_name)
  end

  def test_js_bridge_replace_with
    new_el = @doc.create_element("span")
    @text.__js_call__("replaceWith", [new_el])
    assert_equal(1, @parent.child_nodes.length)
    assert_equal("SPAN", @parent.first_child.tag_name)
  end
end
