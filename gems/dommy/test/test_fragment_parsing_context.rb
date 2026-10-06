# frozen_string_literal: true

require_relative "test_helper"

# insertAdjacentHTML, the outerHTML setter and createContextualFragment
# parse their markup inside a context element (DOM Parsing): its tag and
# namespace decide what the markup becomes, as innerHTML's does.
class TestFragmentParsingContext < Minitest::Test
  include DommyTestHelper

  SVG = "http://www.w3.org/2000/svg"

  def setup
    @doc = make_window("<svg><g id=g></g></svg><table><tr id=tr></tr></table><textarea id=ta></textarea>").document
    @g = @doc.get_element_by_id("g")
  end

  def kinds(nodes)
    nodes.map { |n| [n.namespace_uri, n.local_name] }
  end

  def test_insert_adjacent_html_parses_in_its_context
    @g.insert_adjacent_html("beforeend", "<rect/>")
    @g.insert_adjacent_html("afterend", "<circle/>")
    assert_equal([[SVG, "rect"]], kinds(@g.children.to_a))
    assert_equal([[SVG, "g"], [SVG, "circle"]], kinds(@g.parent_element.children.to_a))

    tr = @doc.get_element_by_id("tr")
    tr.insert_adjacent_html("beforeend", "<td>x</td>")
    assert_equal("TD", tr.first_element_child&.tag_name)

    ta = @doc.get_element_by_id("ta")
    ta.insert_adjacent_html("beforeend", "<b>x</b>")
    assert_equal(["<b>x</b>"], ta.child_nodes.map(&:text_content))
  end

  def test_outer_html_parses_in_the_parent
    @g.outer_html = "<rect/>"
    assert_equal([[SVG, "rect"]], kinds(@doc.query_selector("svg").children.to_a))
  end

  def test_create_contextual_fragment_parses_in_the_start_node
    range = @doc.create_range
    range.select_node_contents(@g)
    assert_equal([[SVG, "rect"]], kinds(range.create_contextual_fragment("<rect/>").children.to_a))
  end

  # An element in another namespace is a foreign context: a start tag
  # becomes an element in its namespace, and one that breaks out of foreign
  # content, such as `<p>`, an HTML element.
  def test_an_element_in_another_namespace_is_a_foreign_context
    range = @doc.create_range
    range.select_node_contents(@doc.create_element_ns("urn:x", "div"))
    nodes = range.create_contextual_fragment("<foo/><p>x").children.to_a
    assert_equal([["urn:x", "foo"], ["http://www.w3.org/1999/xhtml", "p"]], kinds(nodes))
  end

  # Outside an HTML document the XML fragment parser reads the markup, with
  # the context's namespace as its default.
  def test_insert_adjacent_html_in_an_xml_document
    doc = @doc.implementation.create_document("urn:x", "r", nil)
    doc.document_element.insert_adjacent_html("beforeend", "<c/>")
    assert_equal([["urn:x", "c"]], kinds(doc.document_element.children.to_a))
  end

  # innerHTML on an HTML <template> parses with the template as the context
  # element ("in template" mode), so table parts survive; an SVG <template>
  # is an ordinary element with no template contents.
  def test_template_inner_html_parses_in_template_context
    doc = make_window("<template id=t></template><svg><template id=s></template></svg>").document
    t = doc.get_element_by_id("t")
    t.inner_html = "<td>a</td><td>b</td>"
    assert_equal("<td>a</td><td>b</td>", t.inner_html)
    assert_equal(%w[TD TD], t.content.child_nodes.map(&:tag_name))
    assert_equal(0, t.child_nodes.length)

    s = doc.get_element_by_id("s")
    s.inner_html = "<rect/>"
    assert_equal(1, s.child_nodes.length)
    assert_equal("<rect></rect>", s.inner_html)
  end
end
