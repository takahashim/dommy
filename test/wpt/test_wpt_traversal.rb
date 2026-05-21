# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for DOM Traversal (TreeWalker / NodeIterator / NodeFilter).
# WPT: dom/traversal/TreeWalker.html, NodeIterator.html,
# TreeWalker-traversal-reject.html, TreeWalker-traversal-skip.html
class TestWPTTreeWalker < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div id="root">
          <p id="a">one</p>
          <p id="b"><span id="b1">in-b</span></p>
          <p id="c">three</p>
        </div>
      HTML
    )
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
  end

  # ---- construction ----
  # WPT: TreeWalker.html

  def test_createTreeWalker_stores_root
    tw = @doc.create_tree_walker(@root)
    assert_same(@root, tw.root)
  end

  def test_createTreeWalker_default_whatToShow_is_all
    tw = @doc.create_tree_walker(@root)
    assert_equal(Dommy::NodeFilter::SHOW_ALL, tw.what_to_show)
  end

  def test_createTreeWalker_current_node_starts_at_root
    tw = @doc.create_tree_walker(@root)
    assert_same(@root, tw.current_node)
  end

  # ---- nextNode ----
  # WPT: TreeWalker-traversal-skip.html, TreeWalker-acceptNode-filter.html

  def test_nextNode_descends_into_first_child
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    n = tw.next_node
    assert_equal("a", n.id)
  end

  def test_nextNode_visits_in_document_order
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    ids = []
    while (n = tw.next_node)
      ids << n.id
    end

    assert_equal(["a", "b", "b1", "c"], ids)
  end

  def test_nextNode_returns_nil_at_end
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    tw.next_node while tw.next_node
    assert_nil(tw.next_node)
  end

  # ---- previousNode ----

  def test_previousNode_after_walk_returns_prior_elements
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    # a
    tw.next_node
    # b
    tw.next_node
    n = tw.previous_node
    assert_equal("a", n.id)
  end

  # ---- firstChild / lastChild / parentNode ----

  def test_firstChild_returns_first_accepted_child
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    n = tw.first_child
    assert_equal("a", n.id)
  end

  def test_lastChild_returns_last_accepted_child
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    n = tw.last_child
    assert_equal("c", n.id)
  end

  def test_parentNode_from_descendant_returns_to_root
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    # a
    tw.first_child
    # b
    tw.next_node
    # b1 (inside b)
    tw.first_child
    p = tw.parent_node
    assert_equal("b", p.id)
  end

  # ---- whatToShow filter (SHOW_TEXT only) ----
  # WPT: TreeWalker-traversal-skip.html

  def test_whatToShow_text_skips_elements
    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_TEXT)
    texts = []
    while (n = tw.next_node)
      texts << n.text_content.strip
    end

    assert_includes(texts, "one")
    assert_includes(texts, "three")
  end

  # ---- filter callback ----
  # WPT: TreeWalker-acceptNode-filter.html

  def test_filter_callback_accepts_subset
    filter = proc do |node|
      if node.respond_to?(:id) && node.id == "b"
        Dommy::NodeFilter::FILTER_ACCEPT
      else
        Dommy::NodeFilter::FILTER_SKIP
      end
    end

    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT, filter)
    n = tw.next_node
    assert_equal("b", n.id)
    assert_nil(tw.next_node)
  end

  def test_filter_with_acceptNode_object
    filter = Object.new
    def filter.accept_node(node)
      if node.respond_to?(:id) && %w[a c].include?(node.id)
        Dommy::NodeFilter::FILTER_ACCEPT
      else
        Dommy::NodeFilter::FILTER_SKIP
      end
    end

    tw = @doc.create_tree_walker(@root, Dommy::NodeFilter::SHOW_ELEMENT, filter)
    ids = []
    while (n = tw.next_node)
      ids << n.id
    end

    assert_equal(["a", "c"], ids)
  end
end

class TestWPTNodeIterator < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div id="root">
          <p id="a">one</p>
          <p id="b">two</p>
          <p id="c">three</p>
        </div>
      HTML
    )
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
  end

  # WPT: NodeIterator.html

  def test_createNodeIterator_stores_root
    it = @doc.create_node_iterator(@root)
    assert_same(@root, it.root)
  end

  def test_nextNode_starts_at_root
    it = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    assert_same(@root, it.next_node)
  end

  def test_nextNode_walks_document_order
    it = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    # root
    it.next_node
    ids = []
    while (n = it.next_node)
      ids << n.id
    end

    assert_equal(["a", "b", "c"], ids)
  end

  def test_nextNode_returns_nil_at_end
    it = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    it.next_node while it.next_node
    assert_nil(it.next_node)
  end

  def test_previousNode_walks_back
    it = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    # root
    it.next_node
    # a
    it.next_node
    # b
    it.next_node
    assert_equal("b", it.previous_node.id)
  end

  def test_detach_is_noop
    it = @doc.create_node_iterator(@root)
    assert_nil(it.detach)
    # Spec note: detach() is historical and must be a no-op in modern UAs.
    refute_nil(it.next_node)
  end
end
