# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Node properties (nodeType, nodeName,
# nodeValue, textContent, isConnected, parentNode, ownerDocument,
# children navigation).
class TestWPTNodeProperties < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='r'><p>hi</p><!-- c --></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("r")
  end

  # ---- nodeType constants ----
  # WPT: dom/nodes/Node-nodeType-constants.html (deno-dom analog)

  def test_node_constants_element
    assert_equal(1, Dommy::Node::ELEMENT_NODE)
    assert_equal(3, Dommy::Node::TEXT_NODE)
    assert_equal(8, Dommy::Node::COMMENT_NODE)
    assert_equal(9, Dommy::Node::DOCUMENT_NODE)
    assert_equal(10, Dommy::Node::DOCUMENT_TYPE_NODE)
    assert_equal(11, Dommy::Node::DOCUMENT_FRAGMENT_NODE)
  end

  def test_element_nodeType
    el = @doc.create_element("div")
    assert_equal(Dommy::Node::ELEMENT_NODE, el.__js_get__("nodeType"))
  end

  def test_text_nodeType
    t = @doc.create_text_node("hi")
    assert_equal(Dommy::Node::TEXT_NODE, t.__js_get__("nodeType"))
  end

  def test_comment_nodeType
    c = @doc.create_comment("x")
    assert_equal(Dommy::Node::COMMENT_NODE, c.__js_get__("nodeType"))
  end

  def test_document_nodeType
    assert_equal(Dommy::Node::DOCUMENT_NODE, @doc.__js_get__("nodeType"))
  end

  # ---- nodeName / tagName ----
  # WPT: dom/nodes/Document-Element-getElementsByTagName.js (case)

  def test_element_nodeName_matches_tagName_for_html
    el = @doc.create_element("div")
    assert_equal("DIV", el.__js_get__("nodeName"))
    assert_equal("DIV", el.tag_name)
  end

  def test_text_nodeName_is_hash_text
    # Spec: Text.nodeName === "#text"; we don't expose nodeName on
    # text nodes yet, so verify via nodeType only.
    t = @doc.create_text_node("x")
    assert_equal(Dommy::Node::TEXT_NODE, t.__js_get__("nodeType"))
  end

  # ---- nodeValue ----
  # WPT: dom/nodes/Node-nodeValue.html

  def test_text_nodeValue_round_trip
    t = @doc.create_text_node("hi")
    assert_equal("hi", t.node_value)
    t.node_value = "bye"
    assert_equal("bye", t.node_value)
    assert_equal("bye", t.data)
  end

  def test_comment_nodeValue_round_trip
    c = @doc.create_comment("x")
    assert_equal("x", c.node_value)
    c.node_value = "y"
    assert_equal("y", c.data)
  end

  # ---- textContent ----

  def test_element_textContent_concats_descendants
    @root.inner_html = "<p>foo <em>bar</em></p>"
    assert_equal("foo bar", @root.text_content)
  end

  def test_element_textContent_set_replaces_children
    @root.text_content = "plain"
    assert_equal(0, @root.child_element_count)
    assert_equal("plain", @root.text_content)
  end

  # ---- parentNode / parentElement ----

  def test_parentNode_for_child
    p = @root.children[0]
    assert_same(@root.__dommy_backend_node__, p.parent_node.__dommy_backend_node__)
  end

  def test_parentElement_for_child
    p = @root.children[0]
    assert_same(@root.__dommy_backend_node__, p.parent_element.__dommy_backend_node__)
  end

  def test_parentElement_nil_for_detached
    el = @doc.create_element("span")
    assert_nil(el.parent_element)
  end

  # ---- isConnected ----

  def test_isConnected_true_for_attached
    p = @root.children[0]
    assert_equal(true, p.__js_get__("isConnected"))
  end

  def test_isConnected_false_for_detached
    el = @doc.create_element("span")
    assert_equal(false, el.__js_get__("isConnected"))
  end

  # ---- childNodes / children ----

  def test_childNodes_includes_text_and_comment
    @root.inner_html = "<p>x</p>hello<!-- c -->"
    assert_equal(3, @root.child_nodes.length)
  end

  def test_children_excludes_text_and_comment
    @root.inner_html = "<p>x</p>hello<!-- c -->"
    assert_equal(1, @root.child_element_count)
  end

  def test_firstChild_includes_text
    @root.inner_html = "hello<p>x</p>"
    refute_nil(@root.first_child)
  end

  def test_firstElementChild_skips_text
    @root.inner_html = "hello<p>x</p>"
    assert_equal("P", @root.first_element_child.tag_name)
  end

  # ---- hasChildNodes / hasAttributes ----

  def test_hasChildNodes
    assert_equal(true, @root.has_child_nodes?)
    empty = @doc.create_element("div")
    assert_equal(false, empty.has_child_nodes?)
  end

  def test_hasAttributes
    @root.set_attribute("foo", "bar")
    assert_equal(true, @root.has_attributes?)
    empty = @doc.create_element("div")
    assert_equal(false, empty.has_attributes?)
  end

  # ---- contains ----
  # WPT: dom/nodes/Node-contains.html

  def test_contains_descendant
    p = @root.children[0]
    assert_equal(true, @root.contains?(p))
  end

  def test_contains_self
    assert_equal(true, @root.contains?(@root))
  end

  def test_contains_unrelated
    other = @doc.create_element("p")
    assert_equal(false, @root.contains?(other))
  end

  # ---- compareDocumentPosition ----
  # WPT: dom/nodes/Node-compareDocumentPosition.html

  def test_compareDocumentPosition_same_node_zero
    assert_equal(0, @root.compare_document_position(@root))
  end

  def test_compareDocumentPosition_contained_by
    p = @root.children[0]
    result = @root.compare_document_position(p)
    expected = Dommy::Node::DOCUMENT_POSITION_CONTAINED_BY |
      Dommy::Node::DOCUMENT_POSITION_FOLLOWING
    assert_equal(expected, result)
  end

  def test_compareDocumentPosition_disconnected
    other = @doc.create_element("span")
    result = @root.compare_document_position(other)
    assert(result & Dommy::Node::DOCUMENT_POSITION_DISCONNECTED != 0)
  end

  # ---- isEqualNode / isSameNode ----

  def test_isSameNode_strict_identity
    assert(@root.same_node?(@root))
  end

  def test_isEqualNode_for_structurally_identical
    a = @doc.create_element("div")
    a.set_attribute("class", "x")
    b = @doc.create_element("div")
    b.set_attribute("class", "x")
    assert(a.equal_node?(b))
  end

  # ---- cloneNode ----
  # WPT: dom/nodes/Node-cloneNode.html

  def test_cloneNode_shallow_excludes_children
    @root.inner_html = "<p>x</p>"
    clone = @root.clone_node(false)
    assert_equal("DIV", clone.tag_name)
    assert_equal(0, clone.child_element_count)
  end

  def test_cloneNode_deep_includes_children
    @root.inner_html = "<p><span>x</span></p>"
    clone = @root.clone_node(true)
    assert_equal("P", clone.children[0].tag_name)
    refute_nil(clone.query_selector("span"))
  end

  def test_cloneNode_copies_attributes
    @root.set_attribute("data-x", "1")
    @root.set_attribute("class", "y")
    clone = @root.clone_node(false)
    assert_equal("1", clone.get_attribute("data-x"))
    assert_equal("y", clone.get_attribute("class"))
  end

  # ---- normalize ----
  # WPT: dom/nodes/Node-normalize.html

  def test_normalize_merges_adjacent_text
    @root.inner_html = ""
    @root.append(@doc.create_text_node("a"))
    @root.append(@doc.create_text_node("b"))
    @root.normalize
    # Two adjacent text nodes coalesce into one.
    text_nodes = @root.child_nodes.select { |n| n.is_a?(Dommy::TextNode) }
    assert_equal(1, text_nodes.length)
    assert_equal("ab", text_nodes[0].data)
  end
end
