# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG ChildNode `before` / `after` / `replaceWith` all end in a pre-insert
# (or, for replaceWith, a replace) into THIS NODE'S PARENT, so the parent's
# "ensure pre-insertion validity" runs — including the Document-only step 6
# constraints. ParentNode's `replaceChildren` (and `append` / `prepend`) run the
# same check on itself, step 2 included, which a DocumentFragment used to skip.
#
# WPT: dom/nodes/ChildNode-before.html, dom/nodes/ChildNode-after.html,
#      dom/nodes/ChildNode-replaceWith.html,
#      dom/nodes/ParentNode-replaceChildren.html
# Spec: https://dom.spec.whatwg.org/#concept-node-ensure-pre-insertion-validity
class TestWPTChildNodePreInsertionValidity < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # Step 6: a Document may not have a Text child. `documentElement.after(text)`
  # inserts into the document, so it must be rejected even though the same text
  # would be fine next to any element.
  def test_after_on_document_element_rejects_a_text_node
    text = @doc.create_text_node("x")
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doc.document_element.after(text)
    end
    assert_nil text.parent_node
  end

  def test_before_on_document_element_rejects_a_text_node
    text = @doc.create_text_node("x")
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doc.document_element.before(text)
    end
    assert_nil text.parent_node
  end

  # Step 6: only one element may be a child of a document. The document element
  # is already there, so a second one cannot be placed beside it.
  def test_after_on_document_element_rejects_a_second_element
    extra = @doc.create_element("div")
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doc.document_element.after(extra)
    end
    assert_nil extra.parent_node
  end

  # A comment IS a valid document child, so the same call must still work.
  def test_after_on_document_element_accepts_a_comment
    comment = @doc.create_comment("c")
    @doc.document_element.after(comment)

    assert_equal @doc, comment.parent_node
    assert_equal comment, @doc.document_element.next_sibling
  end

  # replaceWith swaps the document element out, so the "already has an element
  # child" count must disregard the node being replaced.
  def test_replace_with_on_document_element_accepts_an_element
    replacement = @doc.create_element("div")
    @doc.document_element.replace_with_nodes(replacement)

    assert_equal [Dommy::DocumentType, Dommy::HTMLDivElement],
                 @doc.child_nodes.to_a.map(&:class)
  end

  def test_replace_with_on_document_element_rejects_a_text_node
    html = @doc.document_element
    text = @doc.create_text_node("x")
    assert_raises(Dommy::DOMException::HierarchyRequestError) { html.replace_with_nodes(text) }
    assert_equal [Dommy::DocumentType, Dommy::HTMLHtmlElement],
                 @doc.child_nodes.to_a.map(&:class)
  end

  # Step 6, the doctype half: a doctype may not follow the document element, so
  # `documentElement.after(doctype)` is rejected while `before` is fine.
  def test_after_on_document_element_rejects_a_doctype
    doctype = @doc.implementation.create_document_type("x", "", "")
    assert_raises(Dommy::DOMException::HierarchyRequestError) do
      @doc.document_element.after(doctype)
    end
  end

  # Step 2: the node must not be an inclusive ancestor of the insertion parent.
  # `text.before(text.parentNode)` would make the parent its own descendant.
  def test_before_rejects_the_nodes_own_parent
    parent = @doc.create_element("div")
    text = @doc.create_text_node("x")
    parent.append_child(text)
    @doc.body.append_child(parent)

    assert_raises(Dommy::DOMException::HierarchyRequestError) { text.before(parent) }
    assert_equal @doc.body, parent.parent_node
    assert_equal parent, text.parent_node
  end

  def test_after_rejects_a_grandparent
    outer = @doc.create_element("div")
    inner = @doc.create_element("span")
    text = @doc.create_text_node("x")
    outer.append_child(inner)
    inner.append_child(text)
    @doc.body.append_child(outer)

    assert_raises(Dommy::DOMException::HierarchyRequestError) { text.after(outer) }
    assert_equal @doc.body, outer.parent_node
  end

  # Step 4: a Document is not an insertable node type.
  def test_replace_with_rejects_a_document
    comment = @doc.create_comment("c")
    @doc.body.append_child(comment)

    assert_raises(Dommy::DOMException::HierarchyRequestError) { comment.replace_with(@doc) }
    assert_equal @doc.body, comment.parent_node
  end

  # Step 2 again, this time with a DocumentFragment parent: replaceChildren on a
  # fragment with the fragment itself is a cycle.
  def test_fragment_replace_children_rejects_itself
    frag = @doc.create_document_fragment

    assert_raises(Dommy::DOMException::HierarchyRequestError) { frag.replace_children(frag) }
  end

  def test_fragment_append_rejects_itself
    frag = @doc.create_document_fragment

    assert_raises(Dommy::DOMException::HierarchyRequestError) { frag.append(frag) }
  end

  def test_fragment_append_child_rejects_itself
    frag = @doc.create_document_fragment

    assert_raises(Dommy::DOMException::HierarchyRequestError) { frag.append_child(frag) }
  end

  # A fragment may still be filled normally.
  def test_fragment_replace_children_accepts_other_nodes
    frag = @doc.create_document_fragment
    div = @doc.create_element("div")
    frag.replace_children(div, "tail")

    assert_equal [div, "#text"], [frag.child_nodes.to_a[0], frag.child_nodes.to_a[1].node_name]
  end

  # Step 2 counts the Document among its descendants' ancestors, so inserting it
  # is a cycle — reported before step 3 notices the reference child is not a
  # child of this node.
  def test_insert_before_rejects_the_document_as_a_cycle
    el = @doc.create_element("div")
    @doc.body.append_child(el)

    assert_raises(Dommy::DOMException::HierarchyRequestError) { el.insert_before(@doc, @doc) }
  end

  def test_append_child_rejects_the_document
    el = @doc.create_element("div")
    @doc.body.append_child(el)

    assert_raises(Dommy::DOMException::HierarchyRequestError) { el.append_child(@doc) }
  end

  # Pre-insert step 1 validates the reference the caller gave; only step 3
  # replaces it when it IS the node being inserted. `insertBefore(x, x)` for an
  # x that is not a child is therefore a NotFoundError, not a silent append.
  def test_insert_before_self_reference_requires_the_node_to_be_a_child
    parent = @doc.create_element("div")
    @doc.body.append_child(parent)
    orphan = @doc.create_comment("c")

    assert_raises(Dommy::DOMException::NotFoundError) { parent.insert_before(orphan, orphan) }
    assert_nil orphan.parent_node
    assert_equal 0, parent.child_nodes.to_a.size
  end

  # …and when it IS a child, step 3 does apply and the node stays put.
  def test_insert_before_self_reference_on_a_child_is_a_no_op
    parent = @doc.create_element("div")
    a = @doc.create_element("i")
    b = @doc.create_element("u")
    parent.append_child(a)
    parent.append_child(b)
    @doc.body.append_child(parent)

    parent.insert_before(a, a)

    assert_equal %w[I U], parent.child_nodes.to_a.map(&:tag_name)
  end

  # The ordinary before/after paths must keep working.
  def test_before_and_after_still_insert_siblings
    mid = @doc.create_element("b")
    @doc.body.append_child(mid)
    head = @doc.create_element("i")
    tail = @doc.create_element("u")
    mid.before(head)
    mid.after(tail)

    assert_equal %w[I B U], @doc.body.child_nodes.to_a.map(&:tag_name)
  end
end
