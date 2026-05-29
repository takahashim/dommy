# frozen_string_literal: true

require_relative "test_helper"

class TestHTMLCollectionBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <header>
          <a id="lnk1" href="/a">A</a>
          <a id="lnk2" href="/b" name="second">B</a>
        </header>
        <form id="f1"><input name="email"></form>
        <form id="f2" name="login"></form>
        <img id="img1" src="/p.png">
      HTML
    )
    @doc = @win.document
  end

  def test_returns_html_collection_for_links
    coll = @doc.links
    assert_kind_of(Dommy::HTMLCollection, coll)
  end

  def test_is_not_array_subclass
    # deno-dom-compatible: HTMLCollection must NOT be an Array subclass.
    refute_kind_of(Array, @doc.forms)
  end

  def test_length
    assert_equal(2, @doc.links.length)
    assert_equal(2, @doc.forms.length)
  end

  def test_size_alias_for_length
    assert_equal(2, @doc.links.size)
  end

  def test_index_accessor_positive
    assert_equal("lnk1", @doc.links[0].id)
    assert_equal("lnk2", @doc.links[1].id)
  end

  def test_index_accessor_negative_ruby_idiom
    assert_equal("lnk2", @doc.links[-1].id)
  end

  def test_item_method
    assert_equal("lnk1", @doc.links.item(0).id)
    assert_equal("lnk2", @doc.links.item(1).id)
    assert_nil(@doc.links.item(99))
  end

  def test_item_negative_returns_nil
    # Per spec, item(i) is positive-only; negative returns nil.
    assert_nil(@doc.links.item(-1))
  end

  def test_named_item_by_id
    el = @doc.links.named_item("lnk2")
    refute_nil(el)
    assert_equal("lnk2", el.id)
  end

  def test_named_item_by_name_attribute
    el = @doc.links.named_item("second")
    refute_nil(el)
    assert_equal("lnk2", el.id)
  end

  def test_named_item_no_match
    assert_nil(@doc.links.named_item("nope"))
    assert_nil(@doc.links.named_item(""))
  end

  def test_index_string_named_lookup
    el = @doc.forms["login"]
    refute_nil(el)
    assert_equal("f2", el.id)
  end

  def test_index_numeric_string
    # "0", "1" etc are treated as indices.
    assert_equal("f1", @doc.forms["0"].id)
  end

  def test_first_last
    assert_equal("lnk1", @doc.links.first.id)
    assert_equal("lnk2", @doc.links.last.id)
  end

  def test_each_iteration
    ids = []
    @doc.links.each { |el| ids << el.id }
    assert_equal(["lnk1", "lnk2"], ids)
  end

  def test_map_via_enumerable
    assert_equal(["lnk1", "lnk2"], @doc.links.map(&:id))
  end

  def test_to_a_returns_array
    arr = @doc.links.to_a
    assert_kind_of(Array, arr)
    assert_equal(2, arr.size)
  end
end

class TestHTMLCollectionLive < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<form id='f'></form>")
    @doc = @win.document
  end

  def test_live_reflects_inserts_after_query
    coll = @doc.forms
    assert_equal(1, coll.length)

    @doc.body.append(@doc.create_element("form"))
    assert_equal(2, coll.length, "HTMLCollection should re-query on access")
  end

  def test_live_reflects_removals
    coll = @doc.forms
    @doc.get_element_by_id("f").remove
    assert_equal(0, coll.length)
  end

  def test_children_returns_live_html_collection
    parent = @doc.create_element("ul")
    @doc.body.append(parent)
    parent.append(@doc.create_element("li"))

    children = parent.children
    assert_kind_of(Dommy::HTMLCollection, children)
    assert_equal(1, children.length)

    parent.append(@doc.create_element("li"))
    assert_equal(2, children.length)
  end
end

class TestFormElementsHTMLCollection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form id="f">
          <input id="email" name="email">
          <input id="password" name="password" type="password">
          <button id="submit">Go</button>
        </form>
      HTML
    )
    @form = @win.document.get_element_by_id("f")
  end

  def test_form_elements_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @form.elements)
  end

  def test_form_elements_named_item_by_name
    el = @form.elements.named_item("email")
    refute_nil(el)
    assert_equal("email", el.id)
  end

  def test_form_elements_index_by_name
    el = @form.elements["password"]
    refute_nil(el)
    assert_equal("password", el.id)
  end
end

class TestTableHTMLCollections < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <table id='t'>
          <thead><tr><th id='h1'>H</th></tr></thead>
          <tbody><tr id='r1'><td>A</td><td>B</td></tr></tbody>
          <tbody><tr id='r2'><td>C</td></tr></tbody>
        </table>
      HTML
    )
    @doc = @win.document
    @table = @doc.get_element_by_id("t")
  end

  def test_table_rows_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @table.rows)
    assert_equal(3, @table.rows.length)
  end

  def test_table_t_bodies_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @table.t_bodies)
    assert_equal(2, @table.t_bodies.length)
  end

  def test_row_cells_is_html_collection
    r1 = @doc.get_element_by_id("r1")
    assert_kind_of(Dommy::HTMLCollection, r1.cells)
    assert_equal(2, r1.cells.length)
  end

  def test_section_rows_is_html_collection
    body = @doc.query_selector("tbody")
    assert_kind_of(Dommy::HTMLCollection, body.rows)
  end
end
