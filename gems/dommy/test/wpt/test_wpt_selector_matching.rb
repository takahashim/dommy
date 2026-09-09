# frozen_string_literal: true

require_relative "../test_helper"

# Namespaces the mixed-tree cases below build elements in.
module SelectorMatchingNamespaces
  SVG = "http://www.w3.org/2000/svg"
  MATHML = "http://www.w3.org/1998/Math/MathML"
  XLINK = "http://www.w3.org/1999/xlink"
end

# An attribute selector's name is ASCII-lowercased only for HTML elements in an
# HTML document; SVG and MathML compare it verbatim.
# WPT: dom/nodes/querySelector-mixed-case.html
class TestWPTMixedCaseAttributeSelectors < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @html = element("div", "html1", "viewBox" => "html-val", "mixedCase" => "html-mixed")
    @svg = element_ns(SelectorMatchingNamespaces::SVG, "svg", "svg1", "viewBox" => "svg-val", "mixedCase" => "svg-mixed")
    @math = element_ns(SelectorMatchingNamespaces::MATHML, "math", "math1", "mathVariant" => "italic")
  end

  def element(tag, id, attrs)
    el = @doc.create_element(tag)
    el.set_attribute("id", id)
    attrs.each { |k, v| el.set_attribute(k, v) }
    @doc.body.append_child(el)
    el
  end

  def element_ns(ns, tag, id, attrs)
    el = @doc.create_element_ns(ns, tag)
    el.set_attribute("id", id)
    attrs.each { |k, v| el.set_attribute(k, v) }
    @doc.body.append_child(el)
    el
  end

  def ids(selector)
    @doc.query_selector_all(selector).to_a.map { |el| el.get_attribute("id") }.sort
  end

  def test_the_exact_spelling_matches_both_kinds
    assert_equal(%w[html1 svg1], ids("[viewBox]"))
  end

  def test_a_lowercased_selector_only_matches_html
    assert_equal(%w[html1], ids("[viewbox]"))
  end

  def test_an_uppercased_selector_only_matches_html
    assert_equal(%w[html1], ids("[VIEWBOX]"))
  end

  def test_mathml_is_case_sensitive_too
    assert_equal(%w[math1], ids("[mathVariant]"))
    assert_empty(ids("[mathvariant]"))
  end

  def test_the_case_rule_reaches_get_attribute_itself
    assert_equal("svg-val", @svg.get_attribute("viewBox"))
    assert_nil(@svg.get_attribute("viewbox"))
    assert(@svg.has_attribute?("viewBox"))
    refute(@svg.has_attribute?("viewbox"))
    # An HTML element stays case-insensitive, whichever way it is asked.
    assert_equal("html-val", @html.get_attribute("viewBox"))
    assert_equal("html-val", @html.get_attribute("VIEWBOX"))
  end
end

# Selectors 4 §6.1 — the namespace part of an attribute selector.
# WPT: dom/nodes/ParentNode-querySelectors-namespaces.html
class TestWPTAttributeSelectorNamespaces < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @svg = @doc.create_element_ns(SelectorMatchingNamespaces::SVG, "svg")
    @doc.body.append_child(@svg)
    @svg.set_attribute_ns(SelectorMatchingNamespaces::XLINK, "xlink:href", "foo")
  end

  def test_any_namespace_matches_by_local_name
    assert_equal([@svg], @doc.query_selector_all("[*|href]").to_a)
    assert_equal(@svg, @doc.query_selector("[*|href]"))
  end

  # An unprefixed selector asks for the attribute in no namespace, which
  # `xlink:href` is not.
  def test_an_unprefixed_selector_does_not_reach_a_namespaced_attribute
    assert_empty(@doc.query_selector_all("[href]").to_a)
    assert_empty(@doc.query_selector_all("[|href]").to_a)
  end

  def test_a_no_namespace_attribute_still_matches_both_shapes
    plain = @doc.create_element_ns(SelectorMatchingNamespaces::SVG, "rect")
    plain.set_attribute("href", "bar")
    @doc.body.append_child(plain)
    assert_equal([plain], @doc.query_selector_all("[href]").to_a)
    assert_equal([@svg, plain], @doc.query_selector_all("[*|href]").to_a)
  end
end

# WPT: dom/nodes/ParentNode-querySelector-All.html
class TestWPTLinkAndTargetPseudos < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # `:link` is about hyperlinks — an `a` or `area` with an href. A `<link href>`
  # is not one, however much its name suggests otherwise.
  def test_link_matches_anchors_and_areas_only
    @doc.head.inner_html = "<link rel='stylesheet' href='x.css'>"
    @doc.body.inner_html = "<a id='a' href='#x'>a</a><area id='ar' href='#y'><a id='noref'>no href</a>"
    assert_equal(%w[a ar], @doc.query_selector_all(":link").to_a.map { |el| el.get_attribute("id") })
    assert_equal(%w[a ar], @doc.query_selector_all(":any-link").to_a.map { |el| el.get_attribute("id") })
    assert_nil(@doc.query_selector("link:link"))
  end

  def test_target_matches_the_element_the_fragment_points_at
    @win.location.__js_set__("hash", "#target")
    @doc.body.inner_html = "<div id='target'></div><div id='other'></div>"
    assert_equal("target", @doc.query_selector(":target").get_attribute("id"))
  end

  # The target element has to be in the document: an id match inside a detached
  # subtree or a fragment is the target of nothing.
  def test_a_detached_subtree_has_no_target
    @win.location.__js_set__("hash", "#target")
    host = @doc.create_element("div")
    host.inner_html = "<div id='target'></div>"
    assert_nil(host.query_selector(":target"))
    assert_empty(host.query_selector_all(":target").to_a)
  end

  def test_a_fragment_has_no_target
    @win.location.__js_set__("hash", "#target")
    fragment = @doc.create_document_fragment
    host = @doc.create_element("div")
    host.set_attribute("id", "target")
    fragment.append_child(host)
    assert_nil(fragment.query_selector(":target"))
  end
end

# WPT: css/selectors/scope-selector.html, dom/nodes/Element-closest.html
class TestWPTScopePseudo < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.inner_html = "<div id='t1'><div id='t2'><div id='t3'><div id='t4'></div></div></div></div>"
  end

  # A Document is not an element, so `:scope` falls back to its document element.
  def test_scope_on_a_document_is_the_document_element
    assert_same(@doc.document_element, @doc.query_selector(":scope"))
    assert_equal(1, @doc.query_selector_all(":scope").to_a.size)
  end

  # A DocumentFragment has no such fallback.
  def test_scope_matches_nothing_in_a_fragment
    fragment = @doc.create_document_fragment
    fragment.append_child(@doc.create_element("div"))
    assert_nil(fragment.query_selector(":scope"))
    assert_empty(fragment.query_selector_all(":scope > div").to_a)
  end

  def test_scope_matches_nothing_in_a_shadow_root
    host = @doc.create_element("x-host")
    @doc.body.append_child(host)
    root = host.attach_shadow(mode: "open")
    root.inner_html = "<div></div>"
    assert_nil(root.query_selector(":scope"))
    assert_empty(root.query_selector_all(":scope > div").to_a)
  end

  # `querySelectorAll` only ever returns descendants, so the context element
  # itself is never in the result even though `:scope` names it.
  def test_scope_never_returns_the_context_element_itself
    assert_empty(@doc.get_element_by_id("t3").query_selector_all(":scope").to_a)
  end

  # `:has()` anchors its relative selector at the candidate, but `:scope` keeps
  # meaning the scoping root of the enclosing query.
  def test_scope_inside_has_still_means_the_outer_scope
    t4 = @doc.get_element_by_id("t4")
    assert_equal("t3", t4.closest(":has(> :scope)").get_attribute("id"))
    assert_equal("t3", t4.closest(":has(:scope)").get_attribute("id"))
  end
end

# A deep clone has to carry the createElementNS metadata across, or an element
# created in another namespace — or in none — comes back as an HTML one.
# WPT: dom/nodes/ParentNode-querySelector-All.html (the detached / fragment runs)
class TestWPTClonedNamespaces < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @doc.body.append_child(@host)
    @host.append_child(named(@doc.create_element("div"), "html"))
    @host.append_child(named(@doc.create_element_ns("", "div"), "none"))
    @host.append_child(named(@doc.create_element_ns("http://www.example.org/ns", "div"), "other"))
    @host.append_child(named(@doc.create_element_ns("urn:x", "p:Mixed"), "prefixed"))
  end

  def named(el, id)
    el.set_attribute("id", id)
    el
  end

  def namespaces_of(root)
    root.children.to_a.to_h { |el| [el.get_attribute("id"), el.namespace_uri] }
  end

  def test_a_deep_clone_keeps_every_descendant_namespace
    assert_equal(namespaces_of(@host), namespaces_of(@host.clone_node(true)))
  end

  def test_a_clone_keeps_the_prefix_and_case_of_a_qualified_name
    clone = @host.clone_node(true).query_selector("#prefixed")
    assert_equal("p", clone.__js_get__("prefix"))
    assert_equal("Mixed", clone.local_name)
    assert_equal("p:Mixed", clone.tag_name)
  end

  def test_a_no_namespace_selector_still_finds_the_clone
    assert_equal(%w[none], @host.clone_node(true).query_selector_all("|div").to_a.map { |el| el.get_attribute("id") })
  end

  def test_the_same_holds_inside_a_document_fragment
    fragment = @doc.create_document_fragment
    fragment.append_child(@host.clone_node(true))
    assert_equal(%w[none], fragment.query_selector_all("|div").to_a.map { |el| el.get_attribute("id") })
  end
end
