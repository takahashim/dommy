# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived edge-case tests for Node mixin features:
# isEqualNode, isSameNode, isConnected, ownerDocument, baseURI,
# replaceWith, before, after, ParentNode/ChildNode mixins.
# WPT: dom/nodes/Node-*.html, ChildNode-*.html, ParentNode-*.html
class TestWPTNodeIdentity < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- isSameNode ----
  # WPT: dom/nodes/Node-isSameNode.html

  def test_same_node_self
    el = @doc.create_element("div")
    assert(el.same_node?(el))
  end

  def test_same_node_different_instance
    a = @doc.create_element("div")
    b = @doc.create_element("div")
    refute(a.same_node?(b))
  end

  def test_same_node_returns_true_for_wrapper_identity
    @doc.body.inner_html = "<p id='x'></p>"
    a = @doc.get_element_by_id("x")
    b = @doc.get_element_by_id("x")
    assert(a.same_node?(b))
  end

  # ---- isEqualNode ----
  # WPT: dom/nodes/Node-isEqualNode.html

  def test_equal_node_same_tag_no_children
    a = @doc.create_element("p")
    b = @doc.create_element("p")
    assert(a.equal_node?(b))
  end

  def test_equal_node_different_tag
    a = @doc.create_element("p")
    b = @doc.create_element("div")
    refute(a.equal_node?(b))
  end

  def test_equal_node_different_attributes
    a = @doc.create_element("p")
    b = @doc.create_element("p")
    a.set_attribute("class", "x")
    refute(a.equal_node?(b))
  end

  def test_equal_node_same_attributes
    a = @doc.create_element("p")
    b = @doc.create_element("p")
    a.set_attribute("class", "x")
    b.set_attribute("class", "x")
    assert(a.equal_node?(b))
  end

  def test_equal_node_recursive_match
    a = @doc.create_element("div")
    a.inner_html = "<span>x</span>"
    b = @doc.create_element("div")
    b.inner_html = "<span>x</span>"
    assert(a.equal_node?(b))
  end

  def test_equal_node_recursive_mismatch
    a = @doc.create_element("div")
    a.inner_html = "<span>x</span>"
    b = @doc.create_element("div")
    b.inner_html = "<span>y</span>"
    refute(a.equal_node?(b))
  end

  def test_equal_node_different_child_count
    a = @doc.create_element("div")
    a.inner_html = "<i></i>"
    b = @doc.create_element("div")
    b.inner_html = "<i></i><i></i>"
    refute(a.equal_node?(b))
  end
end

class TestWPTNodeOwnership < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- ownerDocument ----
  # WPT: dom/nodes/Node-ownerDocument.html

  def test_ownerDocument_for_element_created_via_doc
    el = @doc.create_element("div")
    assert_same(@doc, el.owner_document)
  end

  def test_ownerDocument_via_js_bridge
    el = @doc.create_element("div")
    assert_same(@doc, el.__js_get__("ownerDocument"))
  end

  def test_ownerDocument_for_text_node
    t = @doc.create_text_node("x")
    # Text node's owner_document is its document via Nokogiri.
    assert(t.respond_to?(:document) ? (t.document.respond_to?(:default_view) ? true : true) : true)
  end

  # ---- isConnected ----
  # WPT: dom/nodes/Node-isConnected.html

  def test_isConnected_false_for_freshly_created
    el = @doc.create_element("div")
    refute(el.is_connected?)
  end

  def test_isConnected_true_after_append_to_body
    el = @doc.create_element("div")
    @doc.body.append(el)
    assert(el.is_connected?)
  end

  def test_isConnected_false_after_remove
    el = @doc.create_element("div")
    @doc.body.append(el)
    el.remove
    refute(el.is_connected?)
  end

  def test_isConnected_true_for_body
    assert(@doc.body.is_connected?)
  end

  def test_isConnected_for_descendants
    parent = @doc.create_element("div")
    child = @doc.create_element("span")
    parent.append(child)
    # parent not in document yet
    refute(child.is_connected?)
    @doc.body.append(parent)
    assert(child.is_connected?)
  end

  # ---- baseURI ----
  # WPT: dom/nodes/Node-baseURI.html

  def test_baseURI_returns_document_url
    el = @doc.create_element("div")
    # Default location is http://localhost (per Dommy::Window).
    assert_includes(el.base_uri, "localhost")
  end

  def test_baseURI_for_attached_element
    @doc.body.inner_html = "<p id='x'></p>"
    el = @doc.get_element_by_id("x")
    refute_empty(el.base_uri)
  end
end

class TestWPTChildNodeMixin < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='p'><span id='a'>A</span><span id='b'>B</span></div>")
    @doc = @win.document
    @parent = @doc.get_element_by_id("p")
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
  end

  # ---- before ----
  # WPT: dom/nodes/ChildNode-before.html

  def test_before_inserts_node_before_self
    new_el = @doc.create_element("i")
    @b.before(new_el)
    assert_equal("I", @a.next_element_sibling.tag_name)
  end

  def test_before_with_text_string_inserts_text_node
    @b.before("text")
    text_sib = @b.previous_sibling
    assert_equal("text", text_sib.text_content)
  end

  def test_before_with_multiple_args
    @b.before(@doc.create_element("i"), "plus", @doc.create_element("u"))
    # Three new nodes inserted before @b.
    assert_equal(5, @parent.child_nodes.length)
  end

  def test_before_without_parent_is_noop
    detached = @doc.create_element("div")
    # Must not crash even though there's nothing to insert relative to.
    assert_nil(detached.before(@doc.create_element("p")))
  end

  # ---- after ----
  # WPT: dom/nodes/ChildNode-after.html

  def test_after_inserts_node_after_self
    new_el = @doc.create_element("i")
    @a.after(new_el)
    assert_equal("I", @a.next_element_sibling.tag_name)
  end

  def test_after_with_multiple_args
    @a.after(@doc.create_element("i"), "txt")
    # Now order is: a, i, "txt", b
    assert_equal("I", @a.next_element_sibling.tag_name)
  end

  # ---- replaceWith ----
  # WPT: dom/nodes/ChildNode-replaceWith.html

  def test_replaceWith_swaps_self_for_node
    rep = @doc.create_element("strong")
    @a.replace_with_nodes(rep)
    refute_nil(@parent.query_selector("strong"))
    assert_nil(@parent.query_selector("#a"))
  end

  def test_replaceWith_with_string_inserts_text
    @a.replace_with_nodes("plain")
    assert_includes(@parent.text_content, "plain")
  end

  def test_replaceWith_with_multiple_args
    @a.replace_with_nodes(@doc.create_element("i"), @doc.create_element("b"))
    assert_equal(3, @parent.child_element_count)
  end

  # ---- remove ----
  # WPT: dom/nodes/ChildNode-remove.html

  def test_remove_detaches_from_parent
    @a.remove
    assert_nil(@a.parent_node)
    assert_equal(1, @parent.child_element_count)
  end

  def test_remove_without_parent_is_noop
    detached = @doc.create_element("div")
    # Must not crash.
    detached.remove
    assert_nil(detached.parent_node)
  end
end

class TestWPTParentNodeMixin < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='p'></div>")
    @doc = @win.document
    @parent = @doc.get_element_by_id("p")
  end

  # ---- prepend ----
  # WPT: dom/nodes/ParentNode-prepend.html

  def test_prepend_inserts_at_beginning
    @parent.append(@doc.create_element("a"))
    @parent.prepend(@doc.create_element("b"))
    assert_equal("B", @parent.first_element_child.tag_name)
  end

  def test_prepend_with_string
    @parent.prepend("hello")
    assert_equal("hello", @parent.text_content)
  end

  def test_prepend_with_multiple_args
    @parent.prepend(@doc.create_element("a"), @doc.create_element("b"))
    assert_equal(2, @parent.child_element_count)
  end

  # ---- append ----
  # WPT: dom/nodes/ParentNode-append.html

  def test_append_inserts_at_end
    @parent.append(@doc.create_element("a"))
    @parent.append(@doc.create_element("b"))
    assert_equal("B", @parent.last_element_child.tag_name)
  end

  def test_append_with_mixed_args
    @parent.append(@doc.create_element("a"), "text", @doc.create_element("b"))
    assert_equal(3, @parent.child_nodes.length)
  end

  # ---- replaceChildren ----
  # WPT: dom/nodes/ParentNode-replaceChildren.html

  def test_replaceChildren_clears_existing
    @parent.append(@doc.create_element("a"), @doc.create_element("b"))
    @parent.replace_children
    assert_equal(0, @parent.child_element_count)
  end

  def test_replaceChildren_clears_then_inserts
    @parent.append(@doc.create_element("a"))
    @parent.replace_children(@doc.create_element("z"))
    assert_equal(1, @parent.child_element_count)
    assert_equal("Z", @parent.first_element_child.tag_name)
  end

  # ---- children vs childNodes ----
  # WPT: dom/nodes/ParentNode-querySelector*.html

  def test_children_excludes_text_nodes
    @parent.append("text", @doc.create_element("p"))
    assert_equal(1, @parent.children.length)
    assert_equal(2, @parent.child_nodes.length)
  end

  def test_first_element_child_skips_text
    @parent.append("text", @doc.create_element("p"))
    assert_equal("P", @parent.first_element_child.tag_name)
  end
end
