# frozen_string_literal: true

require_relative "test_helper"

class TestNodeIterator < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.append(@doc.create_element("p").tap { |p| p.text_content = "1" })
    @doc.body.append(@doc.create_element("p").tap { |p| p.text_content = "2" })
    @doc.body.append(@doc.create_element("p").tap { |p| p.text_content = "3" })
    @root = @doc.body
  end

  def test_iterates_elements
    iter = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_ELEMENT)
    visited = []
    while (n = iter.next_node)
      visited << n
    end
    # Includes the root itself (body) + 3 <p> = 4 elements
    assert_equal(4, visited.size)
  end

  def test_iterates_text_nodes
    iter = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_TEXT)
    texts = []
    while (n = iter.next_node)
      texts << n.text_content
    end

    assert_equal(["1", "2", "3"], texts)
  end

  def test_show_comment_zero_when_absent
    iter = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_COMMENT)
    assert_nil(iter.next_node)
  end

  def test_previous_node_walks_backward
    iter = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_TEXT)
    3.times { iter.next_node }
    visited = []
    while (n = iter.previous_node)
      visited << n.text_content
    end

    assert_equal(["3", "2", "1"], visited)
  end

  def test_detach_is_noop
    iter = @doc.create_node_iterator(@root)
    assert_nil(iter.detach)
  end

  def test_what_to_show_property
    iter = @doc.create_node_iterator(@root, Dommy::NodeFilter::SHOW_TEXT)
    assert_equal(Dommy::NodeFilter::SHOW_TEXT, iter.what_to_show)
  end

  def test_root_property
    iter = @doc.create_node_iterator(@root)
    assert_same(@root, iter.root)
  end

  def test_custom_filter
    iter = @doc.create_node_iterator(
      @root,
      Dommy::NodeFilter::SHOW_ELEMENT,
      -> (n) {
        n.is_a?(Dommy::Element) && n.text_content == "2" ? Dommy::NodeFilter::FILTER_ACCEPT : Dommy::NodeFilter::FILTER_REJECT
      }
    )
    accepted = []
    while (n = iter.next_node)
      accepted << n
    end

    assert_equal(1, accepted.size)
    assert_equal("2", accepted.first.text_content)
  end
end
