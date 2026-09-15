# frozen_string_literal: true

require_relative "../test_helper"

# deleteContents step 4 and insertNode steps 1, 6 and 9-11, each of which the
# implementation had short-cut in a way that shows only for some tree shapes.
#
# Spec: https://dom.spec.whatwg.org/#dom-range-deletecontents
#       https://dom.spec.whatwg.org/#concept-range-insert
# Found by differential testing against a Lean 4 formalization of the standard
# (its fixed scenarios range-delete-contents-partially-contained-{end,start} and
# range-insert-node-{start-text-is-self,detached-text-start,moves-preceding-sibling}).
class TestWPTRangeInsertAndDeleteSteps < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @doc.body.append_child(@host)
    @range = @doc.create_range
  end

  def bounds
    [@range.start_container, @range.start_offset, @range.end_container, @range.end_offset]
  end

  def names(node)
    node.child_nodes.to_a.map { |n| n.respond_to?(:local_name) && n.local_name ? n.local_name : n.data }
  end

  # --- deleteContents step 4 ------------------------------------------

  # The start node is an ancestor of the end node, so the common ancestor's
  # children are the start node's — and the one the range reaches into is only
  # partially contained. What the range does contain are that child's children.
  def test_delete_contents_removes_contained_nodes_below_a_partially_contained_child
    @host.inner_html = "<div>ab<i></i>cd</div>"
    inner = @host.first_child
    @range.set_start(@host, 0)
    @range.set_end(inner, 3)
    @range.delete_contents
    assert_equal([], names(inner))
    assert_equal([@host, 0, @host, 0], bounds)
  end

  # The mirror image: the start is inside the child, the end is after it. The
  # contained nodes are the start node's following siblings.
  def test_delete_contents_removes_the_following_siblings_of_a_deep_start
    @host.inner_html = "<div>ab<i></i>cd</div>"
    inner = @host.first_child
    @range.set_start(inner.first_child, 1)
    @range.set_end(@host, 1)
    @range.delete_contents
    assert_equal(["a"], names(inner))
    assert_equal([@host, 1, @host, 1], bounds)
  end

  # --- insertNode step 1 ------------------------------------------------

  def test_insert_node_rejects_the_start_node_itself_without_splitting_it
    @host.inner_html = "ab"
    text = @host.first_child
    @range.set_start(text, 1)
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @range.insert_node(text) }
    assert_equal(["ab"], names(@host))
  end

  def test_insert_node_rejects_a_detached_text_start
    @range.set_start(@doc.create_text_node("ab"), 1)
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @range.insert_node(@doc.create_element("i")) }
  end

  def test_insert_node_rejects_a_comment_start
    @range.set_start(@doc.create_comment("ab"), 1)
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @range.insert_node(@doc.create_element("i")) }
  end

  # A CDATASection is a Text node, so it is split like one rather than taken as
  # the parent to insert into.
  def test_insert_node_splits_a_cdata_section_start
    xml = @doc.implementation.create_document(nil, "root", nil)
    root = xml.document_element
    cdata = xml.create_cdata_section("ab")
    root.append_child(cdata)
    range = xml.create_range
    range.set_start(cdata, 1)
    range.insert_node(xml.create_element("i"))
    assert_equal(["a", "i", "b"], names(root))
  end

  # --- insertNode step 6 ------------------------------------------------

  # Pre-insert validity is checked before step 7 splits the Text start node, so
  # a rejected insertion leaves the tree as it was.
  def test_insert_node_checks_validity_before_splitting
    @host.inner_html = "<p>ab</p>"
    @range.set_start(@host.first_child.first_child, 1)
    assert_raises(Dommy::DOMException::HierarchyRequestError) { @range.insert_node(@host) }
    assert_equal(["ab"], names(@host.first_child))
  end

  # --- insertNode steps 9-11 --------------------------------------------

  # The node is removed before newOffset is counted: moving a node that sat
  # ahead of the reference child takes one off the reference's index.
  def test_insert_node_counts_the_offset_after_removing_a_preceding_sibling
    @host.inner_html = "<a></a><b></b><i></i>"
    a = @host.first_child
    @range.set_start(@host, 2)
    @range.insert_node(a)
    assert_equal(%w[b a i], names(@host))
    assert_equal([@host, 1, @host, 2], bounds)
  end

  # With no reference child, newOffset is the parent's length — also taken after
  # the removal, so it never runs past the end.
  def test_insert_node_appending_a_preceding_sibling_stays_within_the_parent
    @host.inner_html = "<a></a><b></b>"
    a = @host.first_child
    @range.set_start(@host, 2)
    @range.insert_node(a)
    assert_equal(%w[b a], names(@host))
    assert_equal([@host, 1, @host, 2], bounds)
  end
end
