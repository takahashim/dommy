# frozen_string_literal: true

require_relative "test_helper"

# createContextualFragment parses in the range's context element, and the
# fragment it makes belongs to that element's node document — which need not
# be the range's own, when the range's boundary is in another document.
class TestContextualFragmentDocument < Minitest::Test
  def test_the_fragment_belongs_to_the_context_elements_document
    doc = Dommy.parse("<p>a</p>").document
    other = Dommy::DOMParser.new.parse_from_string("<html><body><div id=t></div></body></html>", "text/html")
    range = doc.create_range
    range.select_node_contents(other.get_element_by_id("t"))

    fragment = range.create_contextual_fragment("<b>x</b>")
    assert_same other, fragment.owner_document
    assert_same other, fragment.first_child.owner_document

    # Inserted into the range's document, it is adopted as any other node.
    doc.body.append_child(range.create_contextual_fragment("<i>y</i>"))
    assert_same doc, doc.body.last_child.owner_document
    assert_equal "<p>a</p><i>y</i>", doc.body.inner_html
  end
end
