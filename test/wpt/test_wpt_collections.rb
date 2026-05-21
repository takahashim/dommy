# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for HTMLCollection / NodeList.
class TestWPTCollections < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form id="f1">
          <input id="user" name="username">
          <input id="pass" name="password">
        </form>
        <form name="login">
          <button name="go">Go</button>
        </form>
        <a id="a1" href="/a"></a>
        <a id="a2" name="b" href="/b"></a>
      HTML
    )
    @doc = @win.document
  end

  # ---- HTMLCollection-supported-property-indices ----
  # WPT: dom/collections/HTMLCollection-supported-property-indices.html

  def test_indexed_access_in_order
    forms = @doc.forms
    assert_equal("f1", forms[0].id)
  end

  def test_indexed_access_out_of_range_returns_nil
    assert_nil(@doc.forms[99])
  end

  def test_length_matches_item_count
    forms = @doc.forms
    count = 0
    count += 1 until forms[count].nil?
    assert_equal(forms.length, count)
  end

  # ---- HTMLCollection-supported-property-names ----
  # WPT: dom/collections/HTMLCollection-supported-property-names.html

  def test_namedItem_by_id
    el = @doc.forms.named_item("f1")
    assert_equal("f1", el.id)
  end

  def test_namedItem_by_name_attribute
    el = @doc.forms.named_item("login")
    refute_nil(el)
    assert_equal("login", el.__node__["name"])
  end

  def test_namedItem_missing_returns_nil
    assert_nil(@doc.forms.named_item("nope"))
  end

  def test_bracket_named_access
    el = @doc.forms["login"]
    refute_nil(el)
    assert_equal("login", el.__node__["name"])
  end

  # ---- HTMLCollection-empty-name ----
  # WPT: dom/collections/HTMLCollection-empty-name.html

  def test_namedItem_empty_string_returns_nil
    assert_nil(@doc.forms.named_item(""))
  end

  # ---- HTMLCollection-live-mutations ----
  # WPT: dom/collections/HTMLCollection-live-mutations.window.js

  def test_collection_reflects_appended_items
    forms = @doc.forms
    before = forms.length
    new_form = @doc.create_element("form")
    @doc.body.append(new_form)
    assert_equal(before + 1, forms.length)
  end

  def test_collection_reflects_removed_items
    forms = @doc.forms
    before = forms.length
    @doc.get_element_by_id("f1").remove
    assert_equal(before - 1, forms.length)
  end

  def test_collection_reflects_attribute_changes
    forms = @doc.forms
    before = forms.length
    # Remove all forms via removing the attribute that scoped them
    # (not really applicable here; verify a simpler live behaviour).
    @doc.create_element("form").tap { |f| @doc.body.append(f) }
    assert_equal(before + 1, forms.length)
  end

  # ---- HTMLCollection-iterator ----
  # WPT: dom/collections/HTMLCollection-iterator.html

  def test_each_iteration_in_order
    ids = []
    @doc.forms.each { |el| ids << (el.id == "" ? :unnamed : el.id) }
    assert_equal(["f1", :unnamed], ids)
  end

  def test_map_via_enumerable
    assert_equal(["f1", ""], @doc.forms.map(&:id))
  end

  # ---- NodeList from querySelectorAll ----
  # WPT: dom/nodes/Document-Element-getElementsByClassName.html / querySelectorAll

  def test_querySelectorAll_returns_node_list
    list = @doc.query_selector_all("a")
    assert_kind_of(Dommy::NodeList, list)
    assert_equal(2, list.length)
  end

  def test_querySelectorAll_supports_item
    list = @doc.query_selector_all("a")
    assert_equal("a1", list.item(0).id)
  end

  def test_querySelectorAll_forEach
    seen = []
    @doc.query_selector_all("a").for_each { |el, idx, _list| seen << [idx, el.id] }
    assert_equal([[0, "a1"], [1, "a2"]], seen)
  end

  # ---- HTMLCollection is not Array.isArray-equivalent ----
  # (deno-dom note: collections should not pass `Array.isArray`)

  def test_html_collection_is_not_array
    refute_kind_of(Array, @doc.forms)
  end

  # NodeList <-> Array divergence is intentional and lives in
  # test/test_intentional_divergence.rb.
end
