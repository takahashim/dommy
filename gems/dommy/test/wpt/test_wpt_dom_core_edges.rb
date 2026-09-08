# frozen_string_literal: true

require_relative "../test_helper"

# A walker rooted at the Document has to be able to walk up to that root, or
# `parentNode()` from the body reports no parent and never filters the document
# element on the way there.
# WPT: dom/traversal/TreeWalker.html
class TestWPTTreeWalkerDocumentRoot < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='p'>x</p>")
    @doc = @win.document
  end

  def walker(filter = nil)
    Dommy::TreeWalker.new(@doc, Dommy::NodeFilter::SHOW_ALL, filter)
  end

  def test_parent_node_climbs_to_the_document_element
    w = walker
    w.current_node = @doc.body
    assert_equal("HTML", w.parent_node.tag_name)
  end

  def test_parent_node_climbs_all_the_way_to_the_document
    w = walker
    w.current_node = @doc.body
    w.parent_node
    assert_same(@doc, w.parent_node)
    assert_nil(w.parent_node)
  end

  # A filter that re-enters its own walker is an InvalidStateError, whichever
  # traversal method it re-enters through.
  def test_a_re_entrant_filter_throws
    depth = 0
    w = nil
    w = walker(lambda do |_node|
      if depth.zero?
        depth += 1
        w.first_child
      end
      Dommy::NodeFilter::FILTER_ACCEPT
    end)
    w.current_node = @doc.body
    %i[parent_node first_child last_child previous_sibling next_sibling previous_node next_node].each do |method|
      assert_raises(Dommy::DOMException::InvalidStateError, method.to_s) { w.public_send(method) }
      depth -= 1
    end
  end
end

# WPT: dom/nodes/Document-importNode.html, dom/nodes/ParentNode-replaceChildren.html,
#      dom/nodes/DOMImplementation-createDocumentType.html,
#      dom/nodes/DOMImplementation-createHTMLDocument.html
class TestWPTDocumentNodeEdges < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # An Attr is a Node, so importNode copies it — with its namespace, prefix and
  # value, owned by no element.
  def test_importing_a_namespaced_attribute
    source = @doc.implementation.create_html_document("t")
    source.body.set_attribute_ns("http://example.com/", "p:name", "value")
    original = source.body.get_attribute_node_ns("http://example.com/", "name")
    imported = @doc.import_node(original, true)

    assert_kind_of(Dommy::Attr, imported)
    assert_equal("p", imported.prefix)
    assert_equal("http://example.com/", imported.namespace_uri)
    assert_equal("name", imported.local_name)
    assert_equal("value", imported.value)
    refute_same(original, imported)
    assert_same(@doc, imported.__js_get__("ownerDocument"))
  end

  # A doctype clone keeps its wrapper identity when it joins a tree.
  def test_a_cloned_doctype_keeps_its_identity_once_inserted
    doc = @doc.implementation.create_html_document("title")
    doctype = doc.doctype.clone_node(false)
    doc.__js_call__("replaceChildren", [doctype])
    assert_equal(1, doc.child_nodes.to_a.size)
    assert_same(doctype, doc.child_nodes.to_a.first)
  end

  # createDocumentType is extremely permissive — only a name that could not be
  # serialized back as a doctype is refused.
  def test_createDocumentType_accepts_almost_anything
    ["", "foo", "1foo", "@foo", "edi:{", "edi:%", "a-b:c.j", "_:_"].each do |name|
      assert_equal(name, @doc.implementation.create_document_type(name, "", "").name, name)
    end
  end

  def test_createDocumentType_refuses_a_name_it_could_not_serialize
    ["edi:>", "edi:a ", "a\tb", "a\nb"].each do |name|
      assert_raises(Dommy::DOMException::InvalidCharacterError, name) do
        @doc.implementation.create_document_type(name, "", "")
      end
    end
  end
end

# A URL-valued attribute reads back as a SERIALIZED URL, which is what the URL
# parser produces — percent-encoded, not the raw text.
# WPT: dom/nodes/DOMImplementation-createHTMLDocument.html
class TestWPTResolvedUrlSerialization < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def anchor(href, doc = @doc)
    el = doc.create_element("a")
    el.href = href
    el
  end

  def test_a_non_ascii_query_is_percent_encoded
    assert_equal("http://example.org/?%C3%A4", anchor("http://example.org/?ä").href)
  end

  def test_a_relative_url_resolves_against_the_document
    @doc.body.append_child(a = anchor("/x"))
    assert_equal("http://localhost/x", a.href)
  end

  def test_the_same_holds_in_a_document_built_by_createHTMLDocument
    doc = @doc.implementation.create_html_document("t")
    assert_equal("http://example.org/?%C3%A4", anchor("http://example.org/?ä", doc).href)
  end
end
