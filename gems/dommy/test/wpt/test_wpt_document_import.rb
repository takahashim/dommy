# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Document.importNode.
# WPT: dom/nodes/Document-importNode.html
# Spec: https://dom.spec.whatwg.org/#dom-document-importnode
#
# importNode copies a node into the calling document. Unlike
# adoptNode, the source node is left in place. The `deep` parameter
# controls whether descendants are also copied.
class TestWPTDocumentImportNodeShallow < Minitest::Test
  include DommyTestHelper

  def setup
    @target = make_window.document
    @source = make_window.document
  end

  def test_import_shallow_returns_new_instance
    external = @source.create_element("p")
    imported = @target.import_node(external, false)
    refute_same(external, imported)
  end

  def test_import_shallow_preserves_tag_name
    external = @source.create_element("section")
    imported = @target.import_node(external, false)
    assert_equal("SECTION", imported.tag_name)
  end

  def test_import_shallow_preserves_attributes
    external = @source.create_element("div")
    external.set_attribute("id", "foo")
    external.set_attribute("data-x", "1")
    imported = @target.import_node(external, false)
    assert_equal("foo", imported.get_attribute("id"))
    assert_equal("1", imported.get_attribute("data-x"))
  end

  def test_import_shallow_excludes_children
    external = @source.create_element("div")
    external.append_child(@source.create_element("span"))
    imported = @target.import_node(external, false)
    assert_equal(0, imported.child_nodes.length)
  end

  def test_import_shallow_leaves_source_intact
    external = @source.create_element("p")
    @source.body.append_child(external)
    @target.import_node(external, false)
    # The source node must not be detached or moved.
    assert(external.__dommy_backend_node__.parent)
  end
end

class TestWPTDocumentImportNodeDeep < Minitest::Test
  include DommyTestHelper

  def setup
    @target = make_window.document
    @source = make_window.document
  end

  def test_import_deep_includes_descendants
    external = @source.create_element("div")
    child = @source.create_element("span")
    child.text_content = "leaf"
    external.append_child(child)
    imported = @target.import_node(external, true)
    assert_equal(1, imported.child_nodes.length)
    assert_equal("leaf", imported.first_child.text_content)
  end

  def test_import_deep_preserves_nested_structure
    external = @source.create_element("ul")
    li1 = @source.create_element("li")
    li1.text_content = "a"
    li2 = @source.create_element("li")
    li2.text_content = "b"
    external.append_child(li1)
    external.append_child(li2)
    imported = @target.import_node(external, true)
    assert_equal(2, imported.child_nodes.length)
    assert_equal("a", imported.child_nodes[0].text_content)
    assert_equal("b", imported.child_nodes[1].text_content)
  end

  def test_import_deep_leaves_source_intact
    external = @source.create_element("div")
    external.append_child(@source.create_element("span"))
    @source.body.append_child(external)
    @target.import_node(external, true)
    assert(external.__dommy_backend_node__.parent)
    assert_equal(1, external.child_nodes.length)
  end
end

# "Clone a single node" is what importNode copies with, and its steps 2-3 say
# the copy implements the same interface, in the same namespace, with the same
# attributes — each attribute keeping its own namespace too.
class TestWPTDocumentImportNodeKeepsWhatItCopies < Minitest::Test
  include DommyTestHelper

  SVG = "http://www.w3.org/2000/svg"
  XML = "http://www.w3.org/XML/1998/namespace"

  def setup
    @target = make_window.document
    @source = make_window.document
  end

  # Step 1: a document cannot be imported.
  def test_importing_a_document_is_not_supported
    assert_raises(Dommy::DOMException::NotSupportedError) { @target.import_node(@source, true) }
  end

  def test_importing_a_shadow_root_is_not_supported
    host = @source.create_element("div")
    root = host.attach_shadow(mode: "open")

    assert_raises(Dommy::DOMException::NotSupportedError) { @target.import_node(root, true) }
  end

  def test_the_copy_keeps_the_interface
    pi = @source.create_processing_instruction("target", "d")
    imported = @target.import_node(pi, true)

    assert_instance_of(Dommy::ProcessingInstructionNode, imported)
    assert_equal("target", imported.target)
    assert_equal("d", imported.data)
  end

  def test_the_copy_keeps_the_namespace
    rect = @source.create_element_ns(SVG, "rect")
    imported = @target.import_node(rect, true)

    assert_equal(SVG, imported.namespace_uri)
    assert_equal("rect", imported.local_name)
    assert_equal("rect", imported.tag_name)
  end

  def test_the_copy_keeps_each_attribute_namespace
    div = @source.create_element("div")
    div.set_attribute("a", "1")
    div.set_attribute_ns(XML, "xml:b", "vv")
    imported = @target.import_node(div, true)

    assert_equal("1", imported.get_attribute("a"))
    assert_equal("vv", imported.get_attribute_ns(XML, "b"))
    assert_equal(%w[a xml:b], imported.attributes.map(&:name))
    assert_equal([nil, XML], imported.attributes.map(&:namespace_uri))
  end
end

# `document.cloneNode(deep)` — "clone a single node" step 3 creates the copy
# document empty, so all it ever holds is clones of the original's children.
class TestWPTDocumentCloneNode < Minitest::Test
  include DommyTestHelper

  def test_a_shallow_document_clone_has_no_children
    doc = Dommy.parse("<html><body><div>hi</div></body></html>").document
    copy = doc.clone_node(false)

    assert_equal(0, copy.child_nodes.length)
    assert_nil(copy.document_element)
  end

  def test_a_deep_document_clone_copies_only_its_children
    doc = Dommy.parse("<html><body><div>hi</div></body></html>").document
    copy = doc.clone_node(true)

    assert_equal(1, copy.child_nodes.length)
    assert_equal("HTML", copy.document_element.tag_name)
    assert_equal("hi", copy.query_selector("div").text_content)
    refute_same(doc.document_element, copy.document_element)
  end
end
