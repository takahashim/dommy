# frozen_string_literal: true

require_relative "test_helper"

# Audits the common Node / EventTarget surface across node subtypes — the
# members that should exist on every node (isSameNode, getRootNode, namespace
# lookups, addEventListener) plus a few type-specific ones (splitText, PI data
# methods, fragment ParentNode mutation).
class TestNodeInterface < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='p'>hello</p>")
    @doc = @win.document
  end

  def el = @doc.get_element_by_id("p")
  def text = el.child_nodes.first
  def frag = @doc.__js_call__("createDocumentFragment", [])
  def comment = @doc.__js_call__("createComment", ["c"])
  def pi = @doc.__js_call__("createProcessingInstruction", ["t", "ab"])
  def attr = @doc.__js_call__("createAttribute", ["data-x"])

  # --- isSameNode (every node) ---------------------------------------

  def test_is_same_node
    [el, text, frag, comment, pi, attr].each do |n|
      assert_equal(true, n.__js_call__("isSameNode", [n]), n.class.name)
      assert_equal(false, n.__js_call__("isSameNode", [el]), n.class.name) unless n.equal?(el)
    end
  end

  # --- getRootNode ---------------------------------------------------

  def test_get_root_node
    # An attached element/text node's root is the document.
    assert_kind_of(Dommy::Document, el.__js_call__("getRootNode", [nil]))
    assert_kind_of(Dommy::Document, text.__js_call__("getRootNode", [nil]))
    # A detached fragment is its own root.
    f = frag
    assert_same(f, f.__js_call__("getRootNode", [nil]))
  end

  # --- EventTarget on non-element nodes ------------------------------

  def test_event_target_on_text_and_fragment
    [text, frag, comment, pi, attr].each do |n|
      fired = false
      n.__js_call__("addEventListener", ["ping", proc { fired = true }])
      n.__js_call__("dispatchEvent", [Dommy::Event.new("ping")])
      assert(fired, "#{n.class} should dispatch to its own listener")
    end
  end

  # --- Text.splitText ------------------------------------------------

  def test_split_text
    t = @doc.create_text_node("hello")
    rest = t.__js_call__("splitText", [2])
    assert_equal("he", t.data)
    assert_equal("llo", rest.data)
  end

  def test_split_text_out_of_bounds
    t = @doc.create_text_node("hi")
    assert_raises(Dommy::DOMException::IndexSizeError) { t.__js_call__("splitText", [5]) }
  end

  # --- ProcessingInstruction is CharacterData ------------------------

  def test_pi_character_data_methods
    p = pi
    assert_equal(2, p.__js_get__("length"))
    p.__js_call__("appendData", ["cd"])
    assert_equal("abcd", p.data)
    assert_equal("bc", p.__js_call__("substringData", [1, 2]))
    p.__js_call__("deleteData", [0, 1])
    assert_equal("bcd", p.data)
  end

  # --- DocumentFragment ParentNode/Node mutation ---------------------

  def test_fragment_mutation_methods
    f = frag
    d1 = @doc.create_element("div")
    d2 = @doc.create_element("span")
    f.__js_call__("append", [d1])
    f.__js_call__("prepend", [d2])
    assert_equal(%w[SPAN DIV], f.child_nodes.map(&:tag_name))
    f.__js_call__("removeChild", [d2])
    assert_equal(%w[DIV], f.child_nodes.map(&:tag_name))
    assert_equal(true, f.__js_call__("contains", [d1]))
  end

  # --- compareDocumentPosition is generic (every node) ---------------

  def test_compare_document_position_on_non_element
    # The text node is contained by the body → body CONTAINS it and PRECEDES it.
    pos = text.__js_call__("compareDocumentPosition", [@doc.body])
    assert_equal(Dommy::Node::DOCUMENT_POSITION_CONTAINS | Dommy::Node::DOCUMENT_POSITION_PRECEDING, pos)
    # A detached fragment is disconnected from the document tree.
    disc = frag.__js_call__("compareDocumentPosition", [@doc.body])
    assert_equal(Dommy::Node::DOCUMENT_POSITION_DISCONNECTED, disc & Dommy::Node::DOCUMENT_POSITION_DISCONNECTED)
  end

  # --- leaf nodes throw on child mutation (spec errors) --------------

  def test_leaf_nodes_reject_child_mutation
    [text, comment, pi, attr].each do |n|
      assert_raises(Dommy::DOMException::HierarchyRequestError, n.class.name) do
        n.__js_call__("appendChild", [@doc.create_element("i")])
      end
      assert_raises(Dommy::DOMException::NotFoundError, n.class.name) do
        n.__js_call__("removeChild", [@doc.create_element("i")])
      end
    end
  end

  # --- DocumentType ChildNode (it has the document as parent) --------

  def test_doctype_child_node_methods
    dt = @doc.doctype
    refute_nil(dt)
    dt.__js_call__("before", [@doc.__js_call__("createComment", ["pre"])])
    assert_equal(8, @doc.__js_get__("firstChild").__js_get__("nodeType")) # comment now first
    dt.__js_call__("remove", [])
    assert_nil(@doc.doctype)
  end

  # A standalone (parentless) PI's ChildNode methods are no-ops, not errors.
  def test_pi_child_node_methods_are_noops
    p = pi
    p.__js_call__("remove", [])
    p.__js_call__("before", [@doc.__js_call__("createComment", ["x"])])
    assert_equal("ab", p.data) # unchanged, no error
  end

  # --- compareDocumentPosition + namespace lookups on Element --------

  def test_element_compare_and_namespace
    assert_equal(true, el.__js_call__("isDefaultNamespace", ["http://www.w3.org/1999/xhtml"]))
    assert_equal("http://www.w3.org/1999/xhtml", el.__js_call__("lookupNamespaceURI", [nil]))
    pos = el.__js_call__("compareDocumentPosition", [@doc.body])
    # body contains p → CONTAINS | PRECEDING from p's perspective is CONTAINED_BY|FOLLOWING
    assert_operator(pos, :>, 0)
  end
end
