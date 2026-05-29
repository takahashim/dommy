# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Node mutation methods (appendChild,
# removeChild, replaceChild, insertBefore, ChildNode after/before/
# replaceWith, ParentNode append/prepend/replaceChildren).
class TestWPTNodeMutation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='parent'><span id='a'>A</span><span id='b'>B</span></div>")
    @doc = @win.document
    @parent = @doc.get_element_by_id("parent")
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
  end

  # ---- appendChild ----
  # WPT: dom/nodes/Node-appendChild.html

  def test_appendChild_returns_child
    c = @doc.create_element("span")
    assert_same(c, @parent.append_child(c))
  end

  def test_appendChild_adds_to_end
    c = @doc.create_element("span")
    c.id = "c"
    @parent.append_child(c)
    assert_equal("c", @parent.children.last.id)
  end

  def test_appendChild_moves_existing_child
    @parent.append_child(@a)
    # @a was already a child; appending should move it to the end.
    assert_equal("a", @parent.children.last.id)
    assert_equal(2, @parent.children.length)
  end

  def test_appendChild_cycle_raises_hierarchy_request
    grandparent = @doc.create_element("div")
    grandparent.append(@parent)
    # Can't append `@parent` to itself or to a descendant.
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @parent.append_child(@parent)
    end
  end

  # ---- removeChild ----
  # WPT: dom/nodes/Node-removeChild.html

  def test_removeChild_detaches
    @parent.remove_child(@a)
    assert_nil(@doc.get_element_by_id("a"))
    assert_equal(1, @parent.children.length)
  end

  def test_removeChild_returns_removed_node
    result = @parent.remove_child(@a)
    assert_same(@a, result)
  end

  def test_removeChild_not_a_child_raises_not_found
    detached = @doc.create_element("span")
    assert_raises(Dommy::DOMException::NotFoundError) { @parent.remove_child(detached) }
  end

  # ---- replaceChild ----
  # WPT: dom/nodes/Node-replaceChild.html

  def test_replaceChild_swaps_in_place
    new_el = @doc.create_element("em")
    @parent.replace_child(new_el, @a)
    assert_equal("EM", @parent.children[0].tag_name)
    assert_equal("b", @parent.children[1].id)
  end

  def test_replaceChild_returns_old_child
    new_el = @doc.create_element("em")
    result = @parent.replace_child(new_el, @a)
    assert_same(@a, result)
  end

  # ---- insertBefore ----
  # WPT: dom/nodes/Node-insertBefore.html

  def test_insertBefore_at_position
    c = @doc.create_element("em")
    @parent.insert_before(c, @b)
    assert_equal(["a", nil, "b"], @parent.children.map(&:id).map { |i| i == "" ? nil : i })
  end

  def test_insertBefore_reference_nil_appends
    c = @doc.create_element("em")
    @parent.insert_before(c, nil)
    assert_equal("EM", @parent.children.last.tag_name)
  end

  # ---- ChildNode.remove ----
  # WPT: dom/nodes/ChildNode-remove.js

  def test_childNode_remove_detaches
    @a.remove
    assert_nil(@a.parent_element)
    assert_equal(1, @parent.children.length)
  end

  def test_childNode_remove_detached_is_noop
    detached = @doc.create_element("span")
    detached.remove
    # No exception.
    assert(true)
  end

  # ---- ChildNode.before / after ----
  # WPT: dom/nodes/ChildNode-before.html, ChildNode-after.html

  def test_childNode_before_inserts_sibling
    el = @doc.create_element("em")
    @b.before(el)
    assert_equal("EM", @parent.children[1].tag_name)
  end

  def test_childNode_before_with_string_creates_text_node
    @b.before("hello")
    text = @parent.child_nodes.find { |n| n.is_a?(Dommy::TextNode) }
    refute_nil(text)
    assert_equal("hello", text.text_content)
  end

  def test_childNode_after_inserts_sibling
    el = @doc.create_element("em")
    @a.after(el)
    assert_equal("EM", @parent.children[1].tag_name)
  end

  # ---- ChildNode.replaceWith ----
  # WPT: dom/nodes/ChildNode-replaceWith.html

  def test_childNode_replaceWith_replaces_in_place
    el = @doc.create_element("em")
    @a.__js_call__("replaceWith", [el])
    assert_equal("EM", @parent.children[0].tag_name)
    assert_equal(2, @parent.children.length)
  end

  def test_childNode_replaceWith_string
    @a.__js_call__("replaceWith", ["plain text"])
    refute_nil(@parent.child_nodes.find { |n| n.is_a?(Dommy::TextNode) })
  end

  # ---- ParentNode.append / prepend ----
  # WPT: dom/nodes/ParentNode-append.html, ParentNode-prepend.html

  def test_parentNode_append_adds_to_end
    @parent.append(@doc.create_element("em"))
    assert_equal("EM", @parent.children.last.tag_name)
  end

  def test_parentNode_append_mixed_args
    @parent.append("text ", @doc.create_element("em"))
    assert_match(/text /, @parent.text_content)
  end

  def test_parentNode_prepend_adds_to_start
    @parent.prepend(@doc.create_element("em"))
    assert_equal("EM", @parent.children[0].tag_name)
  end

  def test_parentNode_prepend_string
    @parent.prepend("lead ")
    assert(@parent.text_content.start_with?("lead "))
  end

  # ---- ParentNode.replaceChildren ----
  # WPT: dom/nodes/ParentNode-replaceChildren.html

  def test_replaceChildren_clears_existing
    @parent.replace_children
    assert_equal(0, @parent.children.length)
  end

  def test_replaceChildren_with_new_set
    @parent.replace_children(@doc.create_element("em"), "tail")
    assert_equal(1, @parent.child_element_count)
    assert(@parent.text_content.include?("tail"))
  end
end
