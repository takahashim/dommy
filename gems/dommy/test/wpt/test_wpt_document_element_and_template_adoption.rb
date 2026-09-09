# frozen_string_literal: true

require_relative "../test_helper"

# Two gaps in the mutation model completed by takahashim/dommy#16, both found by
# auditing that issue's completion criteria and both cross-checked against
# headless Chromium 141.
#
#   * `document.documentElement` is the document's first ELEMENT child, so it is
#     null once that element is gone — as are head and body, which resolve
#     through it.
#   * Adopting a `<template>` into another document adopts its template contents
#     DocumentFragment with it: the SAME fragment object, still holding its
#     children.
class TestWPTDocumentElementWithoutARootElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='c'></div>")
    @doc = @win.document
  end

  # The backend's `root` falls back to the doctype when the document has no
  # element child, which is not what `documentElement` means.
  # Spec: https://dom.spec.whatwg.org/#document-element
  def test_document_element_is_nil_after_removing_the_root_element
    @doc.__js_call__("removeChild", [@doc.document_element])

    assert_nil @doc.document_element
    assert_nil @doc.__js_get__("documentElement")
  end

  def test_document_element_is_nil_after_replacing_the_root_with_a_comment
    comment = @doc.create_comment("z")
    removed = @doc.__js_call__("replaceChild", [comment, @doc.document_element])

    assert_equal "HTML", removed.__js_get__("nodeName")
    assert_nil @doc.document_element
    assert_nil @doc.head
    assert_nil @doc.body
    assert_equal "", @doc.title
  end

  def test_the_doctype_still_answers_as_a_child_but_not_as_the_document_element
    @doc.__js_call__("removeChild", [@doc.document_element])

    assert_equal [10], @doc.child_nodes.map { |n| n.__js_get__("nodeType") }
    assert_nil @doc.document_element
  end

  def test_putting_a_root_element_back_restores_it
    html = @doc.document_element
    comment = @doc.create_comment("z")
    @doc.__js_call__("replaceChild", [comment, html])
    @doc.__js_call__("replaceChild", [html, comment])

    assert_same html, @doc.document_element
  end
end

# HTML's adopting steps for `<template>` adopt its template contents too. The
# contents are not in the template's child list, so nothing in the generic
# subtree walk reaches them: without this the adopted template comes out empty.
# Spec: https://html.spec.whatwg.org/#the-template-element
class TestWPTTemplateContentAcrossDocuments < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='c'></div>")
    @doc = @win.document
    @other = @doc.implementation.create_html_document("other")
  end

  def template_with(html)
    template = @doc.create_element("template")
    template.inner_html = html
    template
  end

  def names(node)
    node.child_nodes.map { |n| n.__js_get__("nodeName") }
  end

  def test_adopt_keeps_the_content_object_and_its_children
    template = template_with("<u>hi</u>")
    content = template.content

    @other.adopt_node(template)

    assert_same content, template.content
    assert_equal ["U"], names(template.content)
    assert_equal "<u>hi</u>", template.inner_html
    assert_same @other, template.owner_document
  end

  def test_adopt_leaves_no_content_behind_in_the_source_document
    template = template_with("<u>z</u>")
    @other.adopt_node(template)

    registry = @doc.__internal_template_registry__
    refute registry.has_content?(template.__dommy_backend_node__)
  end

  def test_a_cross_document_insert_adopts_the_content_too
    template = template_with("<u>x</u>")
    @other.body.append_child(template)

    assert_equal ["U"], names(template.content)
    assert_same template, @other.body.first_child
  end

  # A DocumentFragment's children have no wrapper of their own for #adopt_node
  # to reseat, so they took a raw backend adopt that skipped both the wrapper
  # and the template contents.
  def test_a_template_carried_across_inside_a_fragment
    template = template_with("<u>x</u>")
    fragment = @doc.create_document_fragment
    fragment.append_child(template)

    @other.body.append_child(fragment)

    assert_same template, @other.body.first_child
    assert_same @other, template.owner_document
    assert_equal ["U"], names(template.content)
  end

  def test_a_template_deep_inside_an_adopted_subtree
    template = template_with("<b>y</b>")
    content = template.content
    holder = @doc.create_element("div")
    holder.append_child(template)

    @other.adopt_node(holder)

    assert_same template, holder.first_child
    assert_same content, template.content
    assert_equal ["B"], names(template.content)
  end

  # A template's contents can hold further templates, whose own contents live in
  # yet another fragment the walk has to recurse into.
  def test_nested_template_contents
    template = template_with("<template><i>deep</i></template>")
    inner = template.content.first_child

    @other.adopt_node(template)

    assert_same inner, template.content.first_child
    assert_equal ["TEMPLATE"], names(template.content)
    assert_equal ["I"], names(inner.content)
  end

  def test_import_node_deep_copies_the_content_from_the_source_registry
    template = template_with("<u>hi</u>")
    copy = @other.import_node(template, true)

    refute_same template, copy
    assert_equal ["U"], names(copy.content)
    assert_equal ["U"], names(template.content), "the source template keeps its own content"
  end

  # A shallow clone gets an empty template, per the cloning steps.
  def test_import_node_shallow_leaves_the_content_empty
    template = template_with("<u>hi</u>")
    copy = @other.import_node(template, false)

    assert_empty names(copy.content)
  end

  def test_same_document_clone_is_unchanged
    template = template_with("<u>hi</u>")

    assert_equal ["U"], names(template.clone_node(true).content)
    assert_empty names(template.clone_node(false).content)
  end
end
