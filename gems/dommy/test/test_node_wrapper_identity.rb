# frozen_string_literal: true

require_relative "test_helper"

# NodeWrapperCache keys each wrapper by its backend node object, which Makiri
# keeps one of per node for as long as the node's document lives. A pointer
# key let a node of a freed throwaway document — a fragment parsed for
# `DocumentFragment#cloneNode` — hand its address to a brand-new node, which
# then resolved to the stale wrapper of the wrong kind (a data-each clone
# came back a TextNode instead of a Fragment).
class TestNodeWrapperIdentity < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
  end

  # Two nodes at the same address, as a node of a freed document and a new
  # one can be, still get wrappers of their own.
  def test_nodes_sharing_an_address_get_their_own_wrappers
    text = Dommy::Parser.fragment("hello").children.first
    fragment = Dommy::Parser.fragment("<li>row</li>")
    [text, fragment].each { |node| node.define_singleton_method(:pointer_id) { 42 } }

    assert_instance_of(Dommy::TextNode, @doc.wrap_node(text))
    assert_instance_of(Dommy::Fragment, @doc.wrap_node(fragment))
  end

  # The same live node wraps to the same Ruby object across traversals and
  # garbage collections (the DOM's identity).
  def test_the_same_node_wraps_to_the_same_object
    host = @doc.get_element_by_id("host").object_id
    GC.start
    assert_equal(host, @doc.get_element_by_id("host").object_id)
    assert_same(@doc.body.first_child, @doc.get_element_by_id("host"))
  end
end
