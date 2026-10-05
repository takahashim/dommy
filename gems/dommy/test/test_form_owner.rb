# frozen_string_literal: true

require_relative "test_helper"

# HTML's form owner: a listed control's `form` content attribute names a form by
# ID in its own tree, and otherwise (or while disconnected) the nearest ancestor
# form owns it. The owner is read fresh each time, so ID changes, insertions and
# removals are followed without a stored association.
class TestFormOwner < Minitest::Test
  include DommyTestHelper

  LISTED = %w[button fieldset input object output select textarea].freeze

  def setup
    @doc = make_window(<<~HTML).document
      <div id="p"><form id="form1"></form><form id="form2"></form></div>
    HTML
    @form1 = @doc.get_element_by_id("form1")
    @form2 = @doc.get_element_by_id("form2")
  end

  def test_every_listed_control_follows_the_form_attribute
    LISTED.each do |name|
      control = @doc.create_element(name)
      @form1.append_child(control)
      assert_same(@form1, control.form, name)

      control.set_attribute("form", "form2")
      assert_same(@form2, control.form, name)
    end
  end

  def test_an_empty_form_attribute_has_no_owner
    control = @doc.create_element("select")
    control.set_attribute("form", "")
    @form1.append_child(control)
    assert_nil(control.form)

    @form1.id = ""
    assert_nil(control.form)
  end

  def test_the_id_match_is_case_sensitive
    control = @doc.create_element("textarea")
    control.set_attribute("form", "FORM1")
    @form2.append_child(control)
    assert_nil(control.form)
  end

  def test_the_first_element_with_the_id_must_be_a_form
    control = @doc.create_element("output")
    control.set_attribute("form", "form1")
    @form2.append_child(control)
    span = @doc.create_element("span")
    span.id = "form1"
    @form1.parent_node.insert_before(span, @form1)
    assert_nil(control.form)

    @form1.parent_node.append_child(span)
    assert_same(@form1, control.form)
  end

  def test_id_changes_and_removal_are_followed
    control = @doc.create_element("input")
    control.set_attribute("form", "form1")
    @form2.append_child(control)
    @form1.id = "renamed"
    assert_nil(control.form)

    @form1.id = "form1"
    assert_same(@form1, control.form)
    @form1.remove
    assert_nil(control.form)
  end

  def test_a_disconnected_control_uses_its_ancestor_form
    form = @doc.create_element("form")
    control = @doc.create_element("fieldset")
    control.set_attribute("form", "form2")
    form.append_child(control)
    assert_same(form, control.form)
  end

  def test_label_reports_its_labeled_controls_owner
    @doc.body.inner_html = <<~HTML
      <form id="a"><label id="l" for="c">x</label></form>
      <form id="b"></form><input id="c" form="b">
      <form id="m"><label id="lm"><meter></meter></label></form>
    HTML
    assert_equal("b", @doc.get_element_by_id("l").form.id)
    assert_nil(@doc.get_element_by_id("lm").form)
  end

  def test_legend_reports_its_parent_fieldsets_owner_only
    @doc.body.inner_html = <<~HTML
      <form id="a"><fieldset form="b"><legend id="direct">x</legend><div><legend id="nested">y</legend></div></fieldset></form>
      <form id="b"></form>
    HTML
    assert_equal("b", @doc.get_element_by_id("direct").form.id)
    assert_nil(@doc.get_element_by_id("nested").form)
  end

  def test_option_reports_its_selects_owner
    @doc.body.inner_html = <<~HTML
      <form id="a"><select form="b"><option id="o">x</option></select><datalist><option id="d">y</option></datalist></form>
      <form id="b"></form>
    HTML
    assert_equal("b", @doc.get_element_by_id("o").form.id)
    assert_nil(@doc.get_element_by_id("d").form)
  end

  def test_form_data_uses_the_form_owner
    @doc.body.inner_html = <<~HTML
      <form id="a"><input name="inside" value="1"><input name="away" value="2" form="b"></form>
      <form id="b"></form><input name="outside" value="3" form="a">
    HTML
    entries = Dommy::FormData.new(@doc.get_element_by_id("a")).entries.map(&:first)
    assert_equal(%w[inside outside], entries)
  end
end
