# frozen_string_literal: true

require_relative "test_helper"

# HTML's selectedness rules for a <select> (§4.10.7): in a select without
# `multiple`, an option whose selectedness becomes true deselects the others,
# and the selectedness setting algorithm keeps a display-size-1 list from
# having nothing selected (first non-disabled option) or several selected
# (last in tree order wins). The rules are applied when the list changes, so
# `option.selected`, `:checked` and `selectedOptions` all read the settled
# state — not only `select.value`.
class TestSelectSelectedness < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def select_for(html)
    @doc.body.inner_html = html
    @doc.query_selector("select")
  end

  def selected_ids(root = @doc)
    root.query_selector_all("option:checked").map { |o| o.get_attribute("id") }
  end

  def test_setting_an_option_selected_deselects_the_others
    select = select_for('<select><option id="a">A</option><option id="b">B</option><option id="c" selected>C</option></select>')
    a, c = %w[a c].map { |id| @doc.get_element_by_id(id) }

    a.selected = true

    assert a.selected
    refute c.selected
    assert_equal "A", select.value
    assert_equal 0, select.selected_index
    assert_equal %w[a], selected_ids
    assert_equal %w[a], select.selected_options.to_a.map { |o| o.get_attribute("id") }
  end

  def test_a_parsed_single_select_without_a_selected_attribute_selects_its_first_option
    win = make_window('<select id="s"><option id="a">A</option><option id="b">B</option></select>')
    doc = win.document

    assert doc.get_element_by_id("a").selected
    refute doc.get_element_by_id("b").selected
    assert_equal 0, doc.get_element_by_id("s").selected_index
    assert_equal %w[a], selected_ids(doc)
  end

  def test_the_first_option_fallback_skips_disabled_options_and_disabled_optgroups
    select = select_for(<<~HTML)
      <select>
        <option id="a" disabled>A</option>
        <optgroup disabled><option id="b">B</option></optgroup>
        <option id="c">C</option>
      </select>
    HTML
    assert_equal %w[c], selected_ids
    assert_equal "C", select.value
  end

  def test_several_selected_attributes_keep_the_last_in_tree_order
    select_for('<select><option id="a" selected>A</option><option id="b" selected>B</option></select>')
    refute @doc.get_element_by_id("a").selected
    assert @doc.get_element_by_id("b").selected
  end

  def test_deselecting_the_only_selected_option_falls_back_to_the_first
    select_for('<select><option id="a">A</option><option id="b" selected>B</option></select>')
    @doc.get_element_by_id("b").selected = false

    assert @doc.get_element_by_id("a").selected
    assert_equal %w[a], selected_ids
  end

  def test_a_display_size_above_one_has_nothing_selected_by_default
    select = select_for('<select size="3"><option id="a">A</option><option id="b">B</option></select>')
    assert_empty selected_ids
    assert_equal(-1, select.selected_index)
    assert_equal "", select.value
  end

  def test_a_multiple_select_keeps_every_selected_option_and_selects_none_by_default
    select_for('<select multiple><option id="a">A</option><option id="b">B</option><option id="c">C</option></select>')
    assert_empty selected_ids

    @doc.get_element_by_id("a").selected = true
    @doc.get_element_by_id("c").selected = true
    assert_equal %w[a c], selected_ids
  end

  def test_removing_multiple_settles_to_the_last_selected_option
    select = select_for('<select multiple><option id="a" selected>A</option><option id="b" selected>B</option></select>')
    select.remove_attribute("multiple")
    assert_equal %w[b], selected_ids
  end

  def test_value_with_no_matching_option_leaves_nothing_selected
    select = select_for('<select><option id="a">A</option><option id="b">B</option></select>')
    select.value = "zzz"

    assert_empty selected_ids
    assert_equal(-1, select.selected_index)
    assert_equal "", select.value
    # No reset is asked for, so an unrelated mutation does not bring the
    # first-option fallback back.
    @doc.body.set_attribute("data-x", "1")
    assert_empty selected_ids
  end

  def test_selected_index_out_of_range_leaves_nothing_selected
    select = select_for('<select><option id="a">A</option><option id="b">B</option></select>')
    select.selected_index = 1
    assert_equal %w[b], selected_ids

    select.selected_index = -1
    assert_empty selected_ids
  end

  def test_inserting_options_settles_the_list
    select = select_for("<select></select>")
    a = @doc.create_element("option")
    a.set_attribute("id", "a")
    select.append_child(a)
    assert a.selected, "the first option of an empty single-select becomes selected"

    b = @doc.create_element("option")
    b.set_attribute("id", "b")
    select.append_child(b)
    assert_equal %w[a], selected_ids, "a later option does not take over"

    c = @doc.create_element("option")
    c.set_attribute("id", "c")
    c.set_attribute("selected", "")
    select.append_child(c)
    assert_equal %w[c], selected_ids, "an option arriving selected deselects the rest"
  end

  def test_an_option_arriving_selected_wins_wherever_it_lands
    select = select_for('<select><option id="a">A</option><option id="c" selected>C</option><option id="d">D</option></select>')
    %w[a c d].each do |ref_id|
      b = @doc.create_element("option")
      b.set_attribute("id", "b")
      b.selected = true
      select.insert_before(b, @doc.get_element_by_id(ref_id))

      assert_equal %w[b], selected_ids, "inserted before #{ref_id}"
      b.remove
      @doc.get_element_by_id("c").selected = true
    end
  end

  def test_inserting_an_optgroup_and_inner_html_settle_the_list
    select = select_for("<select></select>")
    select.inner_html = '<optgroup><option id="a">A</option></optgroup><option id="b">B</option>'
    assert_equal %w[a], selected_ids

    group = @doc.create_element("optgroup")
    group.inner_html = '<option id="c" selected>C</option>'
    select.append_child(group)
    assert_equal %w[c], selected_ids
  end

  def test_removing_the_selected_option_falls_back_to_the_first_remaining
    select_for('<select><option id="a">A</option><option id="b" selected>B</option><option id="c">C</option></select>')
    @doc.get_element_by_id("b").remove
    assert_equal %w[a], selected_ids
  end

  def test_a_select_inserted_with_its_options_is_settled
    select = @doc.create_element("select")
    select.inner_html = '<option id="a">A</option><option id="b">B</option>'
    @doc.body.append_child(select)
    assert @doc.get_element_by_id("a").selected
  end

  def test_the_selected_attribute_asks_for_a_reset_while_not_dirty
    select_for('<select><option id="a">A</option><option id="b">B</option></select>')
    a, b = %w[a b].map { |id| @doc.get_element_by_id(id) }

    b.set_attribute("selected", "")
    assert_equal %w[b], selected_ids

    b.remove_attribute("selected")
    assert_equal %w[a], selected_ids, "nothing selected -> the first option again"

    # Once dirty, the attribute no longer drives selectedness.
    b.selected = true
    a.set_attribute("selected", "")
    assert_equal %w[a], selected_ids, "a's attribute still counts: a was never set via the IDL setter"
    a.remove_attribute("selected")
    b.set_attribute("selected", "")
    assert_equal %w[a], selected_ids, "b is dirty, so its attribute is ignored and a keeps the fallback"
  end

  def test_form_reset_re_syncs_from_the_attributes_and_settles
    @doc.body.inner_html = '<form id="f"><select><option id="a">A</option><option id="b" selected>B</option></select></form>'
    @doc.get_element_by_id("a").selected = true
    assert_equal %w[a], selected_ids

    @doc.get_element_by_id("f").reset
    assert_equal %w[b], selected_ids
  end
end
