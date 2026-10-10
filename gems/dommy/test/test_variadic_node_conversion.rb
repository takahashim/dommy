# frozen_string_literal: true

require_relative "test_helper"

# The variadic methods (append, prepend, replaceChildren, before, after,
# replaceWith) first "convert nodes into a node": two or more arguments are
# appended to a new DocumentFragment, then the fragment is inserted. Each step
# can fail after the earlier ones moved nodes, and what moved stays moved.
class TestVariadicNodeConversion < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window('<div id="host"><p id="a"></p><p id="b"></p></div>').document
    @host = @doc.get_element_by_id("host")
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
  end

  def fragment?(node) = node.is_a?(Dommy::Fragment)

  # A doctype cannot be a fragment's child: the conversion stops there, and
  # the node appended before it stays in the fragment, out of the tree.
  def test_a_failed_conversion_keeps_the_nodes_it_moved
    doctype = @doc.implementation.create_document_type("x", "", "")

    assert_raises(Dommy::DOMException::HierarchyRequestError) { @b.before(@a, doctype) }

    assert fragment?(@a.parent_node)
    assert_equal [@b], @host.children.to_a
  end

  # The pre-insert check runs on the fragment, after the conversion: a
  # document cannot take a second element, and the elements stay in the
  # fragment.
  def test_a_failed_insert_keeps_the_fragment
    root = @doc.document_element

    assert_raises(Dommy::DOMException::HierarchyRequestError) { root.after(@a, @b) }

    assert fragment?(@a.parent_node)
    assert_same @a.parent_node, @b.parent_node
    assert_empty @host.children.to_a
  end

  def test_append_converts_before_it_checks
    doctype = @doc.implementation.create_document_type("x", "", "")
    target = @doc.create_element("section")

    assert_raises(Dommy::DOMException::HierarchyRequestError) { target.append(@a, doctype) }

    assert fragment?(@a.parent_node)
  end

  # A single argument is not converted into a fragment: a failed insert
  # leaves it where it was.
  def test_a_single_argument_moves_only_when_inserted
    root = @doc.document_element

    assert_raises(Dommy::DOMException::HierarchyRequestError) { root.after(@a) }

    assert_same @host, @a.parent_node
  end

  def test_a_successful_call_inserts_in_argument_order
    @b.before("x", @a, "y")
    assert_equal %w[x a y], @host.child_nodes.to_a.first(3).map { |n| n.is_a?(Dommy::Element) ? n.id : n.text_content }

    @a.replace_with_nodes(@b, @a)
    assert_equal [@b, @a], @host.children.to_a
  end
end
