# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG's by-name attribute family — getAttribute, setAttribute,
# removeAttribute, hasAttribute and toggleAttribute — matches on an attribute's
# QUALIFIED name, not its local name. An element carrying `xml:b` therefore does
# not have an attribute named `b`, and setting `b` adds a second, separate
# attribute rather than overwriting the namespaced one.
#
# Spec: https://dom.spec.whatwg.org/#concept-element-attributes-get-by-name
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTAttributeQualifiedName < Minitest::Test
  include DommyTestHelper

  XML_NS = "http://www.w3.org/XML/1998/namespace"

  def setup
    @win = make_window
    @doc = @win.document
    @el = @doc.create_element("div")
    @el.set_attribute_ns(XML_NS, "xml:b", "vv")
  end

  def names_and_values
    @el.attributes.to_a.map { |a| [a.namespace_uri, a.prefix, a.local_name, a.value] }
  end

  def test_a_prefixed_attribute_is_not_found_by_its_local_name
    assert_nil @el.get_attribute("b")
    refute @el.has_attribute?("b")
  end

  def test_a_prefixed_attribute_is_found_by_its_qualified_name
    assert_equal "vv", @el.get_attribute("xml:b")
    assert @el.has_attribute?("xml:b")
  end

  def test_setAttribute_adds_a_separate_null_namespace_attribute
    @el.set_attribute("b", "zz")

    assert_equal [[XML_NS, "xml", "b", "vv"], [nil, nil, "b", "zz"]], names_and_values
  end

  def test_removeAttribute_by_local_name_leaves_the_prefixed_one
    @el.set_attribute("b", "zz")
    @el.remove_attribute("b")

    assert_equal [[XML_NS, "xml", "b", "vv"]], names_and_values
  end

  def test_toggleAttribute_adds_rather_than_removing_the_prefixed_one
    assert @el.toggle_attribute("b")
    assert_equal [[XML_NS, "xml", "b", "vv"], [nil, nil, "b", ""]], names_and_values
  end

  # setAttribute lower-cases the name only for an element in the HTML namespace
  # whose node document is an HTML document (its step 2). An SVG element keeps
  # the case, and so does the mutation record's attributeName.
  def test_case_is_kept_on_a_non_html_element
    svg = @doc.create_element_ns("http://www.w3.org/2000/svg", "rect")
    @doc.body.append_child(svg)
    records = []
    mo = Dommy::MutationObserver.new(@win, proc { |rs| records.concat(rs) })
    mo.__js_call__("observe", [svg, { "attributes" => true }])

    svg.set_attribute("A", "1")

    assert_equal "1", svg.get_attribute("A")
    assert_nil svg.get_attribute("a")
    taken = mo.__js_call__("takeRecords", []).to_a
    assert_equal 1, taken.size
    assert_equal "A", taken.first.__js_get__("attributeName")
  end

  def test_case_is_folded_on_an_html_element
    html = @doc.create_element("div")
    @doc.body.append_child(html)
    records = []
    mo = Dommy::MutationObserver.new(@win, proc { |rs| records.concat(rs) })
    mo.__js_call__("observe", [html, { "attributes" => true }])

    html.set_attribute("A", "1")

    assert_equal "1", html.get_attribute("a")
    taken = mo.__js_call__("takeRecords", []).to_a
    assert_equal "a", taken.first.__js_get__("attributeName")
  end

  # An Attr reads its value through its own (namespace, local name), so the two
  # namesakes do not report each other's value.
  def test_each_namesake_attr_reports_its_own_value
    @el.set_attribute("b", "zz")
    values = @el.attributes.to_a.map(&:value)

    assert_equal %w[vv zz], values
  end
end
