# frozen_string_literal: true

require_relative "../test_helper"

# innerHTML / outerHTML outside an HTML document run the XML side of the
# fragment serializing and parsing algorithms: the getters write XML (the
# backend only HTML-serializes), and the setters parse the markup as an XML
# fragment, where markup that is not well-formed is a SyntaxError.
#
# WPT: dom/nodes/Node-properties.html, ParentNode-querySelectorAll-scope-change.html
#      (both format a failing XML element through outerHTML)
# Spec: https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#fragment-serializing-algorithm-steps
class TestWPTXMLFragmentSerializing < Minitest::Test
  def setup
    @parser = Dommy::DOMParser.new
  end

  def parse(xml, type = "application/xml")
    @parser.parse_from_string(xml, type)
  end

  def test_outer_html_is_the_xml_serialization
    doc = parse(%(<r xmlns="u"><k id="a" b="1">t<i/></k></r>))
    assert_equal(%(<k xmlns="u" id="a" b="1">t<i/></k>), doc.get_element_by_id("a").outer_html)
  end

  # Each top-level child starts from a fresh namespace state, so it declares
  # the namespace it is in.
  def test_inner_html_serializes_the_children
    doc = parse(%(<r xmlns="u"><k id="a">t<i/></k><!--c--></r>))
    assert_equal(%(t<i xmlns="u"/>), doc.get_element_by_id("a").inner_html)
    assert_equal(%(<k xmlns="u" id="a">t<i/></k><!--c-->), doc.document_element.inner_html)
  end

  def test_an_xhtml_element_keeps_the_xml_forms
    doc = parse(%(<html xmlns="http://www.w3.org/1999/xhtml"><body><p>x<br/></p></body></html>),
      "application/xhtml+xml")
    body = doc.query_selector("body")
    assert_equal(%(<p xmlns="http://www.w3.org/1999/xhtml">x<br /></p>), body.inner_html)
  end

  def test_inner_html_setter_parses_xml_in_the_documents_namespaces
    doc = parse(%(<r xmlns="u" xmlns:p="pu"><k/></r>))
    k = doc.document_element.first_element_child
    k.inner_html = "q<Z/><p:y/>"

    assert_equal(%w[Z p:y], k.children.to_a.map(&:tag_name))
    assert_equal(%w[u pu], k.children.to_a.map(&:namespace_uri))
  end

  # The context is the element itself (the parent for outerHTML), so its own
  # declarations win over the document's, and an element with no default
  # namespace gives none to the fragment.
  def test_setters_parse_in_the_context_elements_namespaces
    doc = parse(%(<r xmlns="u"><k xmlns="u2" xmlns:q="qq"><j/></k><n xmlns=""/></r>))
    k = doc.document_element.first_element_child
    k.inner_html = "<z/><q:z/>"
    assert_equal(%w[u2 qq], k.children.to_a.map(&:namespace_uri))

    k.last_element_child.outer_html = "<y/><q:y/>"
    assert_equal(%w[u2 u2 qq], k.children.to_a.map(&:namespace_uri))

    n = doc.document_element.last_element_child
    n.inner_html = "<z/>"
    assert_nil(n.first_element_child.namespace_uri)
  end

  def test_setters_refuse_markup_that_is_not_well_formed
    k = parse("<r><k/></r>").document_element.first_element_child
    assert_raises(Dommy::DOMException::SyntaxError) { k.inner_html = "<a>" }
    assert_raises(Dommy::DOMException::SyntaxError) { k.inner_html = "</w><w>" }
    assert_raises(Dommy::DOMException::SyntaxError) { k.outer_html = "<a>" }
  end
end

# setAttribute in an XML document makes a null-namespace attribute for any
# valid attribute local name, including the ones that are not XML Names
# ("\u0001", "@click") or hold a colon: the DOM's name rule, not XML's.
#
# WPT: dom/nodes/name-validation.html, dom/nodes/attributes.html
# Spec: https://dom.spec.whatwg.org/#dom-element-setattribute
class TestWPTXMLDocumentSetAttributeNames < Minitest::Test
  def setup
    @doc = Dommy::DOMParser.new.parse_from_string("<r/>", "application/xml")
    @el = @doc.document_element
  end

  def test_names_that_are_not_xml_names
    skip "needs Makiri >= 0.11 (set_loose_dom_attribute)" unless Makiri::XML::Element.method_defined?(:set_loose_dom_attribute)

    ["\u0001", "@click", "a}b", "xlink:href", "xmlns", ":"].each do |name|
      @el.set_attribute(name, "v")
      assert_equal("v", @el.get_attribute(name), name.inspect)
    end
    assert(@el.attributes.to_a.all? { |a| a.namespace_uri.nil? })
  end

  # A null-namespace attribute is still set by (namespace, local name), so a
  # namespaced attribute whose qualified name is the same stays a separate
  # one. (setAttribute, by contrast, changes the first attribute whose
  # qualified name matches — the namespaced one.)
  def test_a_plain_name_beside_a_namespaced_one
    @el.set_attribute_ns("urn:x", "a", "ns")
    @el.set_attribute_ns(nil, "a", "plain")
    assert_equal(2, @el.attributes.length)
    assert_equal("ns", @el.get_attribute_ns("urn:x", "a"))
    assert_equal("plain", @el.get_attribute_ns(nil, "a"))

    @el.set_attribute("a", "changed")
    assert_equal("changed", @el.get_attribute_ns("urn:x", "a"))
    assert_equal("plain", @el.get_attribute_ns(nil, "a"))
  end
end

# The DOM's own name rules, which replaced the XML Name / QName productions.
#
# WPT: dom/nodes/name-validation.html, dom/nodes/Document-createAttribute.html
# Spec: https://dom.spec.whatwg.org/#namespaces
class TestWPTDOMNameValidation < Minitest::Test
  def setup
    @doc = Dommy::Window.new.document
  end

  def test_element_local_names
    ["A\v", "f<oo", ":", "_a", "é", "smallEmoji\u{1F196}", "é-.:_1"].each do |name|
      @doc.create_element(name)
    end
    ["", "a b", "a/b", "a>b", "1a", "-a", ":a b", "_a}", "é<"].each do |name|
      assert_raises(Dommy::DOMException::InvalidCharacterError, name.inspect) { @doc.create_element(name) }
    end
  end

  def test_attribute_local_names
    el = @doc.create_element("div")
    ["\u0001", "0", ":", "invalid^Name"].each do |name|
      el.set_attribute(name, "v")
      el.toggle_attribute(name)
      @doc.create_attribute(name)
    end
    ["", "a b", "a/b", "a=b", "a>b", "a\u0000"].each do |name|
      assert_raises(Dommy::DOMException::InvalidCharacterError, name.inspect) { el.set_attribute(name, "v") }
      assert_raises(Dommy::DOMException::InvalidCharacterError, name.inspect) { el.toggle_attribute(name) }
      assert_raises(Dommy::DOMException::InvalidCharacterError, name.inspect) { @doc.create_attribute(name) }
    end
  end

  def test_qualified_names_split_on_the_first_colon
    el = @doc.create_element("div")
    el.set_attribute_ns("u", "\u0001:attr", "v")
    assert_equal("v", el.get_attribute_ns("u", "attr"))
    assert_raises(Dommy::DOMException::InvalidCharacterError) { el.set_attribute_ns("u", ":attr", "v") }
    assert_raises(Dommy::DOMException::InvalidCharacterError) { el.set_attribute_ns("u", "p:a=b", "v") }
  end

  def test_doctype_names
    ["", "\v", "1foo", "edi:%"].each { |name| @doc.implementation.create_document_type(name, "", "") }
    ["a b", "a>b", "a\u0000"].each do |name|
      assert_raises(Dommy::DOMException::InvalidCharacterError, name.inspect) do
        @doc.implementation.create_document_type(name, "", "")
      end
    end
  end
end

# A prefixed element parsed from XML has the local name after the prefix, and
# a type selector (with no namespace declared) or getElementsByTagNameNS finds
# it by that name.
#
# WPT: dom/nodes/ParentNode-querySelector-namespace-tagname-attribute.html
# Spec: https://dom.spec.whatwg.org/#concept-element-local-name
class TestWPTParsedPrefixedElementLocalName < Minitest::Test
  def setup
    @doc = Dommy::DOMParser.new.parse_from_string(
      %(<cp:coreProperties xmlns:cp="urn:cp" id="target"><dc:title xmlns:dc="urn:dc"/></cp:coreProperties>),
      "application/xml"
    )
    @target = @doc.get_element_by_id("target")
  end

  def test_the_names
    assert_equal("coreProperties", @target.local_name)
    assert_equal("cp:coreProperties", @target.tag_name)
    assert_equal("urn:cp", @target.namespace_uri)
  end

  def test_lookups_by_local_name
    assert_same(@target, @doc.query_selector("coreProperties"))
    assert_same(@target, @doc.query_selector("*|coreProperties"))
    assert_equal("title", @doc.query_selector("title").local_name)
    assert_equal(1, @doc.get_elements_by_tag_name_ns("urn:cp", "coreProperties").length)
  end
end

# A DocumentFragment (a ShadowRoot included) is never a child: its parent and
# siblings are null, not undefined.
#
# WPT: dom/nodes/Node-properties.html
class TestWPTFragmentHasNoSiblings < Minitest::Test
  def test_document_fragment
    frag = Dommy::Window.new.document.create_document_fragment
    %w[parentNode nextSibling previousSibling].each { |key| assert_nil(frag.__js_get__(key), key) }
  end

  def test_shadow_root
    doc = Dommy::Window.new.document
    host = doc.body.append_child(doc.create_element("div"))
    root = host.attach_shadow({"mode" => "open"})
    %w[parentNode parentElement nextSibling previousSibling nodeValue].each do |key|
      assert_nil(root.__js_get__(key), key)
    end
  end
end

# createDocument appends the doctype it is given — that node, adopted into the
# new document — not a copy of it.
#
# WPT: dom/nodes/Node-properties.html (xmlDoc / xmlDoctype)
# Spec: https://dom.spec.whatwg.org/#dom-domimplementation-createdocument
class TestWPTCreateDocumentAppendsTheDoctype < Minitest::Test
  def test_the_doctype_itself_becomes_the_first_child
    impl = Dommy::Window.new.document.implementation
    doctype = impl.create_document_type("q", "p", "s")
    doc = impl.create_document(nil, "root", doctype)

    assert_same(doctype, doc.child_nodes.to_a.first)
    assert_same(doc, doctype.parent_node)
    assert_same(doc, doctype.owner_document)
    assert_equal(2, doc.child_nodes.length)
  end
end

# An element parsed from XML in no namespace has a null namespaceURI (not the
# HTML namespace), so it keeps its case when it moves into an HTML document.
#
# WPT: domparsing/DOMParser-parseFromString-xml-CDATA.html
# Spec: https://dom.spec.whatwg.org/#dom-element-namespaceuri
class TestWPTXMLElementInNoNamespace < Minitest::Test
  def setup
    @win = Dommy::Window.new
    @xml = Dommy::DOMParser.new(@win).parse_from_string("<r><k/></r>", "application/xml")
  end

  def test_its_namespace_is_null
    assert_nil(@xml.document_element.namespace_uri)
  end

  def test_it_is_not_an_html_element_in_an_html_document
    doc = @win.document
    imported = doc.import_node(@xml.document_element, true)
    assert_nil(imported.namespace_uri)
    assert_equal("r", imported.tag_name)
    assert_instance_of(Dommy::Element, imported.first_element_child)
    adopted = doc.adopt_node(@xml.document_element.first_element_child)
    assert_equal("k", adopted.tag_name)
  end
end

# An element's interface follows its namespace, whatever the document: an
# XHTML element parsed from XML is an HTML element, prefixed or not.
#
# WPT: domparsing/DOMParser-parseFromString-xml.html
# Spec: https://dom.spec.whatwg.org/#concept-element-interface
class TestWPTXHTMLElementInterface < Minitest::Test
  def test_parsed_elements_are_html_elements
    xhtml = "http://www.w3.org/1999/xhtml"
    doc = Dommy::DOMParser.new.parse_from_string(
      %(<html xmlns="#{xhtml}"><body><h:p xmlns:h="#{xhtml}"/><k xmlns=""/></body></html>), "application/xhtml+xml"
    )
    body = doc.query_selector("body")
    assert_instance_of(Dommy::HTMLBodyElement, body)
    assert_equal([Dommy::HTMLParagraphElement, Dommy::Element], body.children.to_a.map(&:class))
  end
end

# Moving an upper-case HTML-namespace element (`BR`, `INPUT`) from an XML
# document into an HTML one: Makiri will not import it (Lexbor would make it
# that element), so the adopt falls back to importNode's copy and keeps the
# DOM's name on the moved wrapper.
class TestWPTAdoptUpperCaseHTMLElement < Minitest::Test
  XHTML = "http://www.w3.org/1999/xhtml"

  def setup
    skip "needs Makiri >= 0.11" unless Makiri::HTML::Document.method_defined?(:create_element_ns)

    @win = Dommy::Window.new
    @doc = @win.document
  end

  def element(markup)
    Dommy::DOMParser.new(@win).parse_from_string(markup, "application/xml").document_element
  end

  def test_adopt_and_append_keep_the_node_and_its_name
    [%(<BR xmlns="#{XHTML}"/>), %(<h:BR xmlns:h="#{XHTML}"/>)].each do |markup|
      el = element(markup)
      assert_same(el, @doc.adopt_node(el))
      assert_equal(["BR", XHTML], [el.local_name, el.namespace_uri])
      assert_same(@doc, el.owner_document)

      el = element(markup)
      @doc.body.append_child(el)
      assert_equal("BR", el.local_name)
      assert_same(@doc.body, el.parent_node)
    end
  end

  # The fallback copy keeps an XML <template>'s children, which are its real
  # children in an XML document, and their wrappers move with them.
  def test_a_template_in_the_moved_subtree_keeps_its_children
    el = element(%(<div xmlns="#{XHTML}"><BR/><template><b/></template></div>))
    b = el.last_element_child.first_element_child
    @doc.body.append_child(el)
    assert_same(el.last_element_child, b.parent_node)
    assert_same(@doc, b.owner_document)
  end
end

# importNode copies an XML <template>'s children too.
#
# WPT: dom/nodes/Document-importNode.html
# Spec: https://dom.spec.whatwg.org/#concept-node-clone
class TestWPTImportXMLTemplate < Minitest::Test
  def test_the_children_are_copied
    doc = Dommy::Window.new.document
    xml = Dommy::DOMParser.new.parse_from_string(
      %(<div xmlns="http://www.w3.org/1999/xhtml"><template><b/></template></div>), "application/xml"
    )
    copy = doc.import_node(xml.document_element, true)
    assert_equal(%w[b], copy.first_element_child.children.to_a.map(&:local_name))
  end
end
