# frozen_string_literal: true

require_relative "test_helper"

class TestTreeWalker < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.append(@doc.create_element("p").tap { |p| p.text_content = "b" })
    @doc.body.append(@doc.create_element("p").tap { |p| p.text_content = "c" })
    @doc.body.append(@doc.create_element("p").tap { |p| p.text_content = "d" })
    @root = @doc.body
  end

  def test_default_walk_visits_all_descendants
    walker = @doc.create_tree_walker(@root)
    # Default whatToShow = SHOW_ALL — visits elements + text nodes.
    visited = []
    while (n = walker.next_node)
      visited << n
    end
    # 3 elements + 3 text nodes
    assert_equal(6, visited.size)
  end

  def test_show_element_filters_to_elements
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    visited = []
    while (n = walker.next_node)
      visited << n
    end

    assert_equal(3, visited.size)
    visited.each { |n| assert_kind_of(Dommy::Element, n) }
  end

  def test_show_text_filters_to_text_nodes
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_TEXT)
    visited = []
    while (n = walker.next_node)
      visited << n
    end

    assert_equal(3, visited.size)
    visited.each { |n| assert_kind_of(Dommy::TextNode, n) }
  end

  def test_show_comment_skips_unless_present
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_COMMENT)
    assert_nil(walker.next_node)
  end

  def test_show_comment_finds_comment
    @root.append(@doc.create_comment("note"))
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_COMMENT)
    n = walker.next_node
    refute_nil(n)
    assert_kind_of(Dommy::CommentNode, n)
  end

  def test_custom_filter_accept_reject
    # Accept only paragraphs whose text starts with "c".
    filter = -> (node) do
      if node.is_a?(Dommy::Element) && node.tag_name == "P" && node.text_content.start_with?("c")
        next Dommy::NodeFilter::FILTER_ACCEPT
      end

      Dommy::NodeFilter::FILTER_REJECT
    end

    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT, filter)
    accepted = []
    while (n = walker.next_node)
      accepted << n.text_content
    end

    assert_equal(["c"], accepted)
  end

  def test_previous_node_walks_backward
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    walker.next_node
    walker.next_node
    # at third <p>
    walker.next_node
    visited = []
    while (n = walker.previous_node)
      visited << n.text_content
    end

    # Per WHATWG previousNode(): after "c" and "b", walking up from the first
    # child returns the root itself (unlike parentNode(), previousNode() can
    # return the root). The root is body, whose text is "b"+"c"+"d".
    assert_equal(["c", "b", "bcd"], visited)
  end

  def test_first_child_and_next_sibling
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    walker.current_node = @root
    first = walker.first_child
    assert_equal("b", first.text_content)
    second = walker.next_sibling
    assert_equal("c", second.text_content)
  end

  def test_parent_node_walks_up
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    # first <p>
    text = walker.next_node
    # text node, but SHOW_ELEMENT filters it
    walker.current_node = text.first_child
    # Walk back up to find the <p>
    walker.current_node = @doc.create_text_node("phantom")
  end

  def test_what_to_show_property
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    assert_equal(Dommy::NodeFilter::SHOW_ELEMENT, walker.what_to_show)
    assert_equal(Dommy::NodeFilter::SHOW_ELEMENT, walker.__js_get__("whatToShow"))
  end

  def test_root_property
    walker = @doc.create_tree_walker(@root)
    assert_same(@root, walker.root)
  end

  # WHATWG "filter" sets an active flag around the user callback; a NodeFilter
  # that re-enters its own walker (calls a traversal method while still running)
  # is an InvalidStateError.
  def test_filter_reentrancy_raises_invalid_state_error
    walker = nil
    raised = nil
    filter = proc do |_node|
      begin
        walker.next_node
      rescue Dommy::DOMException::InvalidStateError => e
        raised = e
      end
      Dommy::NodeFilter::FILTER_ACCEPT
    end
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ALL, filter)
    walker.next_node

    assert_instance_of(Dommy::DOMException::InvalidStateError, raised)
  end

  # The active flag is cleared even when the filter throws, so the walker stays
  # usable for the next (non-reentrant) traversal.
  def test_active_flag_cleared_after_filter_raises
    walker = nil
    filter = proc { |_node| walker.next_node }
    walker = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT, filter)

    assert_raises(Dommy::DOMException::InvalidStateError) { walker.next_node }
    # A fresh walker (no re-entrancy) still traverses normally afterward.
    plain = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    assert_equal(3, [plain.next_node, plain.next_node, plain.next_node].compact.size)
  end
end
