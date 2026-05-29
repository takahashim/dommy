# frozen_string_literal: true

require_relative "test_helper"

class TestHTMLOptionsCollection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <select id='s'>
          <option value='a'>A</option>
          <option value='b' selected>B</option>
          <option value='c'>C</option>
        </select>
      HTML
    )
    @doc = @win.document
    @sel = @doc.get_element_by_id("s")
  end

  def test_options_returns_HTMLOptionsCollection
    assert_kind_of(Dommy::HTMLOptionsCollection, @sel.options)
  end

  def test_inherits_from_HTMLCollection
    assert_kind_of(Dommy::HTMLCollection, @sel.options)
  end

  def test_length_matches_options
    assert_equal(3, @sel.options.length)
  end

  def test_item_at_index
    assert_equal("a", @sel.options.item(0).value)
  end

  def test_indexed_lookup
    assert_equal("b", @sel.options[1].value)
  end

  def test_named_item_by_id
    @sel.inner_html = "<option id='x' value='v1'>v</option>"
    assert_equal("v1", @sel.options.named_item("x").value)
  end

  def test_add_appends_when_before_is_nil
    new_opt = @doc.create_element("option")
    new_opt.value = "d"
    @sel.options.add(new_opt)
    assert_equal(4, @sel.options.length)
    assert_equal("d", @sel.options.item(3).value)
  end

  def test_add_inserts_before_given_option
    new_opt = @doc.create_element("option")
    new_opt.value = "z"
    @sel.options.add(new_opt, @sel.options.item(0))
    assert_equal("z", @sel.options.item(0).value)
  end

  def test_add_inserts_before_integer_index
    new_opt = @doc.create_element("option")
    new_opt.value = "z"
    @sel.options.add(new_opt, 1)
    assert_equal("z", @sel.options.item(1).value)
  end

  def test_remove_at_index
    @sel.options.remove(1)
    assert_equal(2, @sel.options.length)
    refute_equal("b", @sel.options.item(1).value)
  end

  def test_selectedIndex_get
    assert_equal(1, @sel.options.selected_index)
  end

  def test_selectedIndex_set_via_collection
    @sel.options.selected_index = 2
    assert_equal(2, @sel.options.selected_index)
  end

  def test_length_setter_truncates
    @sel.options.length = 1
    assert_equal(1, @sel.options.length)
    assert_equal("a", @sel.options.item(0).value)
  end

  def test_length_setter_extends_with_blank_options
    @sel.options.length = 5
    assert_equal(5, @sel.options.length)
    extra = @sel.options.item(3)
    assert_equal("OPTION", extra.tag_name)
  end

  def test_length_setter_zero_clears
    @sel.options.length = 0
    assert_equal(0, @sel.options.length)
  end

  def test_js_bridge_selectedIndex
    assert_equal(1, @sel.options.__js_get__("selectedIndex"))
    @sel.options.__js_set__("selectedIndex", 0)
    assert_equal(0, @sel.options.selected_index)
  end

  def test_js_bridge_add_remove
    new_opt = @doc.create_element("option")
    new_opt.value = "d"
    @sel.options.__js_call__("add", [new_opt, nil])
    assert_equal(4, @sel.options.length)
    @sel.options.__js_call__("remove", [0])
    assert_equal(3, @sel.options.length)
  end

  def test_live_reflects_external_append
    coll = @sel.options
    before = coll.length
    @sel.append_child(@doc.create_element("option"))
    assert_equal(before + 1, coll.length)
  end
end
