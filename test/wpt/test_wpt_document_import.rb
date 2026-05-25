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
    assert(external.__node__.parent)
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
    assert(external.__node__.parent)
    assert_equal(1, external.child_nodes.length)
  end
end
