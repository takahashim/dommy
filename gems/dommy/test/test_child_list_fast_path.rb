# frozen_string_literal: true

require_relative "test_helper"

# A node's childNodes and children answer `length` and `[i]` from the
# backend's own child list, so a loop over their indices is not O(n²) — and
# stay live: a change shows at the next read, however it was made.
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
end
