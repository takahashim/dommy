# frozen_string_literal: true

require_relative "../test_helper"

# `document.body` is the first child of the html element — the document
# element, when it is the HTML namespace's `html` — that is a `body` or a
# `frameset` in the HTML namespace. The setter replaces that element, or
# appends to the document element when there is none.
#
# WPT: html/dom/documents/dom-tree-accessors/Document.body.html
# Spec: https://html.spec.whatwg.org/multipage/dom.html#dom-document-body
class TestWPTDocumentBody < Minitest::Test
  TEST_NS = "http://example.org/test"

  def setup
    @window = Dommy::Window.new
  end

  # A createHTMLDocument document without its document element.
  def create_document
    doc = @window.document.implementation.create_html_document("")
    doc.remove_child(doc.document_element)
    doc
  end

  def html_in(doc) = doc.append_child(doc.create_element("html"))

  def test_childless_document_and_html_element
    doc = create_document
    assert_nil doc.body
    html_in(doc)
    assert_nil doc.body
  end

  def test_the_first_body_or_frameset_child_of_the_html_element
    doc = create_document
    html = html_in(doc)
    b = html.append_child(doc.create_element("body"))
    html.append_child(doc.create_element("frameset"))
    assert_same b, doc.body

    doc = create_document
    html = html_in(doc)
    f = html.append_child(doc.create_element("frameset"))
    html.append_child(doc.create_element("body"))
    assert_same f, doc.body
  end

  def test_a_non_html_html_element_has_no_body
    doc = create_document
    html = doc.append_child(doc.create_element_ns(TEST_NS, "html"))
    html.append_child(doc.create_element("body"))
    html.append_child(doc.create_element("frameset"))
    assert_nil doc.body
  end

  def test_non_html_body_and_frameset_are_skipped
    %w[body frameset].each do |name|
      doc = create_document
      html = html_in(doc)
      html.append_child(doc.create_element_ns(TEST_NS, name))
      b = html.append_child(doc.create_element("body"))
      assert_same b, doc.body, name
    end
  end

  def test_only_children_of_the_html_element_count
    %w[body frameset].each do |name|
      doc = create_document
      html = html_in(doc)
      html.append_child(doc.create_element("x")).append_child(doc.create_element(name))
      element = html.append_child(doc.create_element(name))
      assert_same element, doc.body, name
    end
  end

  def test_a_body_or_frameset_root_is_no_body
    [["body", "frameset"], ["frameset", "body"]].each do |root_name, child_name|
      doc = create_document
      root = doc.append_child(doc.create_element(root_name))
      assert_nil doc.body
      root.append_child(doc.create_element(child_name))
      assert_nil doc.body
    end
    %w[body frameset].each do |name|
      doc = create_document
      doc.append_child(doc.create_element_ns(TEST_NS, name))
      assert_nil doc.body
    end
  end

  def test_setting_a_string_or_a_div
    doc = @window.document
    original = doc.body
    assert_raises(Dommy::Bridge::TypeError) { doc.__js_set__("body", "text") }
    assert_raises(Dommy::DOMException::HierarchyRequestError) { doc.body = doc.create_element("div") }
    assert_same original, doc.body
  end

  def test_setting_with_no_root_element
    doc = create_document
    assert_raises(Dommy::DOMException::HierarchyRequestError) { doc.body = doc.create_element("body") }
    assert_nil doc.body
  end

  def test_setting_a_new_body_or_frameset
    %w[body frameset].each do |name|
      doc = @window.document.implementation.create_html_document("")
      element = doc.create_element(name)
      doc.body = element
      assert_same element, doc.body, name
    end
  end

  def test_setting_replaces_the_first_body_or_frameset
    doc = create_document
    html = html_in(doc)
    f = html.append_child(doc.create_element("frameset"))
    b = doc.create_element("body")
    doc.body = b
    assert_nil f.parent_node
    assert_same b, doc.body

    doc = create_document
    html = html_in(doc)
    b = html.append_child(doc.create_element("body"))
    f1 = html.append_child(doc.create_element("frameset"))
    f2 = doc.create_element("frameset")
    doc.body = f2
    assert_nil b.parent_node
    assert_same html, f1.parent_node
    assert_same f2, doc.body
    assert_same f1, f2.next_sibling
  end

  def test_setting_appends_to_a_root_that_is_not_html
    doc = create_document
    doc.append_child(doc.create_element("test"))
    new_body = doc.create_element("body")
    doc.body = new_body
    assert_same new_body, doc.document_element.first_child
    assert_nil doc.body
  end

  # `document.head` is defined the same way: a child of the html element, so
  # a root that is not HTML's `html` has neither.
  #
  # Spec: https://html.spec.whatwg.org/multipage/dom.html#the-head-element-2
  def test_head_and_body_need_the_html_element
    doc = create_document
    svg = doc.append_child(doc.create_element_ns("http://www.w3.org/2000/svg", "svg"))
    svg.append_child(doc.create_element("head"))
    svg.append_child(doc.create_element("body"))
    assert_nil doc.head
    assert_nil doc.body

    doc = create_document
    html = html_in(doc)
    html.append_child(doc.create_element_ns(TEST_NS, "head"))
    head = html.append_child(doc.create_element("head"))
    assert_same head, doc.head
  end

  # The same in an XML document: an XHTML document gets a body to append.
  def test_an_xhtml_document
    doc = @window.document.implementation.create_document(Dommy::Internal::Namespaces::HTML, "html", nil)
    body = doc.create_element("body")
    doc.body = body
    assert_same body, doc.body
    assert_same doc.document_element, body.parent_node
  end
end
