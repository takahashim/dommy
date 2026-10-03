# frozen_string_literal: true

require_relative "test_helper"

# A node's childNodes and children answer `length` and `[i]` from the
# backend's own child list, and keep the length and the last child read until
# the tree changes, so a loop over their indices is O(n) — and stay live: a
# change shows at the next read, however it was made.
class TestChildListFastPath < Minitest::Test
  def setup
    @doc = Dommy.parse("<ul id=t><li>a</li>text<li>b</li></ul>").document
    @ul = @doc.get_element_by_id("t")
  end

  def test_length_and_items_follow_every_change
    nodes = @ul.__js_get__("childNodes")
    elements = @ul.__js_get__("children")
    assert_equal [3, 2], [nodes.length, elements.length]
    assert_equal "text", nodes.item(1).text_content
    assert_same @ul.first_element_child, elements.item(0)

    li = @doc.create_element("li")
    @ul.insert_before(li, @ul.first_child)
    assert_equal [4, 3], [nodes.length, elements.length]
    assert_same li, nodes.item(0)
    assert_same li, elements.item(0)

    fragment = @doc.create_document_fragment
    fragment.append_child(@doc.create_element("li"))
    fragment_nodes = fragment.__js_get__("childNodes")
    @ul.append_child(fragment)
    assert_equal [0, 5], [fragment_nodes.length, nodes.length]
    assert_nil nodes.item(9)
  end

  # A shadow root's lists are live and the same object each time, as an
  # element's are.
  def test_a_shadow_roots_lists_are_live
    host = @doc.create_element("div")
    shadow = host.attach_shadow("mode" => "open")
    nodes = shadow.__js_get__("childNodes")
    assert_same nodes, shadow.__js_get__("childNodes")

    shadow.append_child(@doc.create_element("p"))
    assert_equal [1, 1], [nodes.length, shadow.__js_get__("children").length]
  end

  # Forward and back, each index after the first is a step from the last.
  def test_a_loop_over_the_indices_lists_the_children_once_for_each
    @ul.inner_html = (1..50).map { |i| "<li>#{i}</li>" }.join
    lookups = 0
    backend = @ul.__dommy_backend_node__
    backend.define_singleton_method(:element_children) { lookups += 1; super() }
    elements = @ul.__js_get__("children")

    forward = (0...elements.length).map { |i| elements.item(i).text_content }
    backward = (elements.length - 1).downto(0).map { |i| elements.item(i).text_content }
    assert_equal (1..50).map(&:to_s), forward
    assert_equal forward.reverse, backward
    assert_equal 2, lookups, "the length once, the first item once"
  ensure
    backend.singleton_class.remove_method(:element_children)
  end

  # What is kept goes when the tree changes, by any route: a parse into the
  # node, a removal mid-loop, a child moved to another document.
  def test_what_is_kept_goes_with_any_change
    nodes = @ul.__js_get__("childNodes")
    assert_equal ["a", 3], [nodes.item(0).text_content, nodes.length]

    @ul.inner_html = "<li>x</li><li>y</li>"
    assert_equal ["x", "y", 2], [nodes.item(0).text_content, nodes.item(1).text_content, nodes.length]

    nodes.item(0).remove
    assert_equal ["y", 1], [nodes.item(0).text_content, nodes.length]

    other = Dommy.parse("<p>").document
    other.body.append_child(other.adopt_node(nodes.item(0)))
    assert_equal [nil, 0], [nodes.item(0), nodes.length]
  end
end
