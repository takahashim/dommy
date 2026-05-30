# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for innerHTML / outerHTML / DocumentFragment /
# insertAdjacentHTML.
# WPT: domparsing/innerhtml-*.html, outerhtml-*.html,
# insert-adjacent-html.html, createDocumentFragment.html
class TestWPTInnerHTML < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- innerHTML getter ----
  # WPT: domparsing/innerhtml-01.html

  def test_innerHTML_empty_element_returns_empty_string
    el = @doc.create_element("div")
    assert_equal("", el.inner_html)
  end

  def test_innerHTML_simple_text
    el = @doc.create_element("div")
    el.text_content = "hello"
    assert_equal("hello", el.inner_html)
  end

  def test_innerHTML_with_child_element
    el = @doc.create_element("div")
    el.inner_html = "<span>x</span>"
    assert_equal("<span>x</span>", el.inner_html)
  end

  def test_innerHTML_round_trip_preserves_attributes
    el = @doc.create_element("div")
    el.inner_html = "<p class='c' id='p1'>x</p>"
    # Attribute order isn't guaranteed by HTML5 serialization but
    # presence must be.
    assert_includes(el.inner_html, "id=\"p1\"")
    assert_includes(el.inner_html, "class=\"c\"")
  end

  # ---- innerHTML setter ----
  # WPT: domparsing/innerhtml-02.html

  def test_innerHTML_setter_replaces_children
    el = @doc.create_element("div")
    el.append(@doc.create_element("span"))
    el.inner_html = "<p>new</p>"
    assert_equal(1, el.child_element_count)
    assert_equal("P", el.first_element_child.tag_name)
  end

  def test_innerHTML_setter_to_empty_clears_children
    el = @doc.create_element("div")
    el.inner_html = "<span>a</span><span>b</span>"
    el.inner_html = ""
    assert_equal(0, el.child_element_count)
  end

  def test_innerHTML_setter_with_text_only
    el = @doc.create_element("div")
    el.inner_html = "just text"
    assert_equal("just text", el.text_content)
  end

  def test_innerHTML_setter_with_multiple_top_level_nodes
    el = @doc.create_element("div")
    el.inner_html = "<p>a</p><p>b</p><p>c</p>"
    assert_equal(3, el.child_element_count)
  end

  def test_innerHTML_setter_with_nested_structure
    el = @doc.create_element("div")
    el.inner_html = "<section><h1>t</h1><p>b</p></section>"
    section = el.first_element_child
    assert_equal("SECTION", section.tag_name)
    assert_equal(2, section.child_element_count)
  end

  # ---- innerHTML preserves whitespace ----

  def test_innerHTML_preserves_whitespace_between_elements
    el = @doc.create_element("div")
    el.inner_html = "<p>a</p> <p>b</p>"
    # 2 elements + 1 text
    assert_equal(3, el.child_nodes.length)
  end
end

class TestWPTOuterHTML < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='p'><span id='c'>x</span></div>")
    @doc = @win.document
    @parent = @doc.get_element_by_id("p")
    @child = @doc.get_element_by_id("c")
  end

  # ---- outerHTML getter ----
  # WPT: domparsing/outerhtml-01.html

  def test_outerHTML_includes_self
    assert_includes(@child.outer_html, "<span")
    assert_includes(@child.outer_html, "x</span>")
  end

  def test_outerHTML_includes_attributes
    assert_includes(@child.outer_html, "id=\"c\"")
  end

  def test_outerHTML_for_void_element
    img = @doc.create_element("img")
    img.set_attribute("src", "/a.png")
    assert_includes(img.outer_html, "<img")
    assert_includes(img.outer_html, "src=\"/a.png\"")
  end

  # ---- outerHTML setter ----
  # WPT: domparsing/outerhtml-02.html

  def test_outerHTML_setter_replaces_self_in_parent
    @child.outer_html = "<b id='b1'>bold</b>"
    refute_nil(@parent.query_selector("#b1"))
    assert_nil(@parent.query_selector("#c"))
  end

  def test_outerHTML_setter_with_multiple_top_level_nodes
    @child.outer_html = "<i>a</i><i>b</i>"
    assert_equal(2, @parent.child_element_count)
  end

  def test_outerHTML_setter_with_text_inserts_text_node
    @child.outer_html = "just text"
    assert_equal("just text", @parent.text_content)
  end

  def test_outerHTML_setter_without_parent_is_noop
    # Per WHATWG DOM Parsing spec: parent is null → return silently.
    detached = @doc.create_element("div")
    detached.outer_html = "<p>x</p>"
    assert_equal("DIV", detached.tag_name)
  end

  def test_outerHTML_setter_on_documentElement_throws_NoModificationAllowedError
    # Per spec: parent is the Document → NoModificationAllowedError.
    assert_raises(Dommy::DOMException::NoModificationAllowedError) do
      @doc.document_element.outer_html = "<html><body>x</body></html>"
    end
  end
end

class TestWPTInsertAdjacentHTML < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><div id='inner'></div></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @inner = @doc.get_element_by_id("inner")
  end

  # WPT: domparsing/insert-adjacent-html.html

  def test_beforebegin_inserts_before_self_in_parent
    @inner.insert_adjacent_html("beforebegin", "<p id='x'></p>")
    assert_same(@outer.first_element_child, @outer.query_selector("#x"))
  end

  def test_afterbegin_prepends_inside_self
    @inner.insert_adjacent_html("afterbegin", "<p id='x'></p>")
    assert_equal("P", @inner.first_element_child.tag_name)
    assert_equal("x", @inner.first_element_child.id)
  end

  def test_beforeend_appends_inside_self
    @inner.insert_adjacent_html("beforeend", "<p id='x'></p>")
    assert_equal("x", @inner.last_element_child.id)
  end

  def test_afterend_inserts_after_self_in_parent
    @inner.insert_adjacent_html("afterend", "<p id='x'></p>")
    assert_equal("x", @inner.next_element_sibling.id)
  end

  def test_beforebegin_without_parent_raises
    # WHATWG: beforebegin/afterend with no parent throws NoModificationAllowedError.
    detached = @doc.create_element("div")
    assert_raises(Dommy::DOMException::NoModificationAllowedError) do
      detached.insert_adjacent_html("beforebegin", "<p></p>")
    end
  end

  def test_afterend_without_parent_raises
    detached = @doc.create_element("div")
    assert_raises(Dommy::DOMException::NoModificationAllowedError) do
      detached.insert_adjacent_html("afterend", "<p></p>")
    end
  end

  def test_insertAdjacentHTML_parses_multiple_top_level_nodes
    @inner.insert_adjacent_html("beforeend", "<p>a</p><p>b</p>")
    assert_equal(2, @inner.child_element_count)
  end
end

class TestWPTDocumentFragment < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- createDocumentFragment ----
  # WPT: dom/nodes/Document-createDocumentFragment.html

  def test_createDocumentFragment_returns_Fragment
    frag = @doc.create_document_fragment
    assert_kind_of(Dommy::Fragment, frag)
  end

  def test_fragment_nodeType_is_11
    frag = @doc.create_document_fragment
    assert_equal(11, frag.__js_get__("nodeType"))
  end

  def test_fragment_starts_empty
    frag = @doc.create_document_fragment
    assert_equal(0, frag.child_element_count)
    assert_empty(frag.child_nodes)
  end

  def test_fragment_appendChild_adds_to_fragment
    frag = @doc.create_document_fragment
    frag.append_child(@doc.create_element("p"))
    assert_equal(1, frag.child_element_count)
  end

  def test_fragment_textContent_aggregates_children
    frag = @doc.create_document_fragment
    p1 = @doc.create_element("p")
    p1.text_content = "a"
    p2 = @doc.create_element("p")
    p2.text_content = "b"
    frag.append_child(p1)
    frag.append_child(p2)
    assert_equal("ab", frag.text_content)
  end

  # ---- fragment is consumed when appended ----
  # WPT: dom/nodes/Node-appendChild.html (fragment semantics)

  def test_fragment_children_moved_when_appended_to_element
    frag = @doc.create_document_fragment
    frag.append_child(@doc.create_element("p"))
    frag.append_child(@doc.create_element("p"))

    host = @doc.create_element("div")
    @doc.body.append(host)
    host.append_child(frag)

    assert_equal(2, host.child_element_count)
    assert_equal(0, frag.child_element_count)
  end
end

class TestWPTFragmentParser < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- fragment parser quirks ----
  # WPT: domparsing/innerhtml-table.html

  def test_innerHTML_for_table_section_parses_rows
    table = @doc.create_element("table")
    @doc.body.append(table)
    tbody = @doc.create_element("tbody")
    table.append(tbody)
    tbody.inner_html = "<tr><td>a</td></tr><tr><td>b</td></tr>"
    assert_equal(2, tbody.child_element_count)
  end

  def test_innerHTML_for_select_parses_options
    sel = @doc.create_element("select")
    sel.inner_html = "<option>1</option><option>2</option>"
    assert_equal(2, sel.child_element_count)
  end

  def test_innerHTML_normalizes_unclosed_tag
    el = @doc.create_element("div")
    el.inner_html = "<p>open"
    assert_equal(1, el.child_element_count)
    assert_equal("P", el.first_element_child.tag_name)
  end

  def test_innerHTML_escapes_text_content
    el = @doc.create_element("div")
    el.text_content = "<not html>"
    assert_includes(el.inner_html, "&lt;")
    refute_includes(el.inner_html, "<not")
  end
end
