# frozen_string_literal: true

require_relative "test_helper"

# `document`'s named properties (HTML §3.1.7): embed / form / iframe / img /
# object by name, object by id, img by id only with a name, an HTMLCollection
# when several match, and tree order. Mirrors WPT
# html/dom/documents/dom-tree-accessors/nameditem-*.html.
class TestDocumentNamedAccess < Minitest::Test
  def setup
    @doc = Dommy.parse(<<~HTML).document
      <embed name="test1">
      <embed name="test2"><embed name="test2">
      <embed id="test3">
      <object data="x" name="obj1"></object>
      <object data="x" id="obj2"></object>
      <img name="img1" id="img_id">
      <img id="just_id">
      <img name="42">
    HTML
  end

  def test_name_lookup
    assert_kind_of Dommy::HTMLEmbedElement, @doc.__js_get__("test1")
    assert_kind_of Dommy::HTMLObjectElement, @doc.__js_get__("obj1")
  end

  def test_object_by_id_and_img_by_id_with_a_name
    assert_kind_of Dommy::HTMLObjectElement, @doc.__js_get__("obj2")
    assert_kind_of Dommy::HTMLImageElement, @doc.__js_get__("img_id")
  end

  def test_embed_by_id_is_not_exposed
    refute_includes @doc.__js_named_props__, "test3"
    assert_same Dommy::Bridge::ABSENT, @doc.__js_get__("test3")
  end

  def test_img_by_id_without_a_name_is_not_exposed
    refute_includes @doc.__js_named_props__, "just_id"
  end

  def test_multiple_matches_return_an_html_collection
    collection = @doc.__js_get__("test2")
    assert_kind_of Dommy::HTMLCollection, collection
    assert_equal 2, collection.length
  end

  def test_names_are_in_tree_order
    names = @doc.__js_named_props__
    assert_operator names.index("test1"), :<, names.index("test2")
    assert_operator names.index("img_id"), :<, names.index("img1")
    assert_equal "42", names.last
  end
end
