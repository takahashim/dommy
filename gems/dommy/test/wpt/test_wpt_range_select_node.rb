# frozen_string_literal: true

require_relative "../test_helper"

# `selectNode` and the four sibling setters position a range *relative to* a
# node, so they need the node's parent as the boundary's container. A node with
# no parent — a Document, a detached DocumentFragment, a freshly created
# element — has no such container, and WHATWG throws rather than inventing one.
#
# Without the check, the boundary ends up with a null container: `startContainer`
# is non-nullable in the IDL, and a null container's length reads as 0, so the
# next `setEnd` on the same range reports a bogus IndexSizeError.
#
# WPT: dom/ranges/Range-selectNode.html
# Spec: https://dom.spec.whatwg.org/#dom-range-selectnode
class TestWPTRangeSelectNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'><p id='p'>text</p></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @p = @doc.get_element_by_id("p")
    @range = @doc.create_range
  end

  def assert_needs_parent(&block)
    assert_raises(Dommy::DOMException::InvalidNodeTypeError, &block)
  end

  # --- a node with a parent is fine -------------------------------

  def test_select_node_spans_the_node
    @range.select_node(@p)
    assert_equal(@host, @range.start_container)
    assert_equal(0, @range.start_offset)
    assert_equal(@host, @range.end_container)
    assert_equal(1, @range.end_offset)
  end

  def test_sibling_setters_use_the_parent_as_container
    @range.set_start_before(@p)
    @range.set_end_after(@p)
    assert_equal(@host, @range.start_container)
    assert_equal(0, @range.start_offset)
    assert_equal(@host, @range.end_container)
    assert_equal(1, @range.end_offset)
  end

  # --- a node with no parent throws -------------------------------

  def test_select_node_on_the_document_raises
    assert_needs_parent { @range.select_node(@doc) }
  end

  def test_select_node_on_a_detached_fragment_raises
    assert_needs_parent { @range.select_node(@doc.create_document_fragment) }
  end

  def test_select_node_on_a_freshly_created_element_raises
    assert_needs_parent { @range.select_node(@doc.create_element("div")) }
  end

  def test_set_start_before_on_the_document_raises
    assert_needs_parent { @range.set_start_before(@doc) }
  end

  def test_set_start_after_on_the_document_raises
    assert_needs_parent { @range.set_start_after(@doc) }
  end

  def test_set_end_before_on_the_document_raises
    assert_needs_parent { @range.set_end_before(@doc) }
  end

  def test_set_end_after_on_the_document_raises
    assert_needs_parent { @range.set_end_after(@doc) }
  end

  def test_a_failed_setter_leaves_the_range_alone
    @range.set_start(@p, 0)
    @range.set_end(@p, 1)
    assert_needs_parent { @range.set_start_before(@doc) }
    assert_equal(@p, @range.start_container)
    assert_equal(0, @range.start_offset)
    assert_equal(@p, @range.end_container)
    assert_equal(1, @range.end_offset)
  end

  # --- selectNodeContents rejects a doctype -----------------------

  def test_select_node_contents_on_a_doctype_raises
    doctype = @doc.doctype
    skip "document has no doctype" unless doctype

    assert_needs_parent { @range.select_node_contents(doctype) }
  end

  def test_select_node_contents_on_the_document_is_allowed
    @range.select_node_contents(@doc)
    assert_equal(@doc, @range.start_container)
    assert_equal(0, @range.start_offset)
    assert_equal(@doc.child_nodes.length, @range.end_offset)
  end
end
