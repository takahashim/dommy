# frozen_string_literal: true

require_relative "test_helper"

# The shared constraint validation API and the ValidityState constraints, as
# HTML defines them.
class TestConstraintValidationSpec < Minitest::Test
  include DommyTestHelper

  def setup_page(html)
    @win = make_window(html)
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  def test_radio_group_is_missing_when_any_member_is_required
    setup_page("<form><input type=radio name=g id=a required><input type=radio name=g id=b></form>")
    assert el("b").validity.value_missing
    el("b").checked = true
    refute el("a").validity.value_missing
  end

  def test_select_placeholder_label_option
    setup_page(<<~HTML)
      <select id=s required><option value="">Pick</option><option value="">empty</option></select>
      <select id=g required><optgroup><option value="">in group</option></optgroup></select>
      <select id=m required multiple><option value="" selected>x</option></select>
    HTML
    assert el("s").validity.value_missing
    el("s").selected_index = 1
    refute el("s").validity.value_missing
    refute el("g").validity.value_missing
    refute el("m").validity.value_missing
  end

  def test_url_type_mismatch_uses_the_url_parser
    setup_page("<input id=u type=url>")
    el("u").value = "mailto:a@b"
    refute el("u").validity.type_mismatch
    el("u").value = "http://exa mple.com"
    assert el("u").validity.type_mismatch
    el("u").value = "not a url"
    assert el("u").validity.type_mismatch
  end

  def test_validation_message_for_each_failure_and_normalized_custom_message
    setup_page("<input id=n type=number min=5 value=1><input id=t maxlength=2><textarea id=a></textarea>")
    assert_equal "Value must be greater than or equal to 5.", el("n").validation_message
    el("t").__internal_user_edit_value__("abc")
    assert el("t").validity.too_long
    refute_empty el("t").validation_message
    el("t").value = "abc"
    refute el("t").validity.too_long
    el("a").set_custom_validity("one\r\ntwo\rthree")
    assert_equal "one\ntwo\nthree", el("a").validation_message
  end

  def test_invalid_events_are_trusted_and_form_check_covers_image_buttons
    setup_page("<form id=f><input type=image id=i></form>")
    el("i").set_custom_validity("bad")
    trusted = nil
    el("i").add_event_listener("invalid", proc { |e| trusted = e.__js_get__("isTrusted") })
    refute el("f").check_validity
    assert trusted
  end

  def test_fieldset_is_barred_but_keeps_a_custom_error_and_lists_object
    setup_page("<fieldset id=fs><object id=o></object><input id=i></fieldset>")
    fieldset = el("fs")
    fieldset.set_custom_validity("x")
    assert fieldset.validity.custom_error
    refute fieldset.will_validate
    assert_equal "", fieldset.validation_message
    assert_equal %w[o i], fieldset.elements.to_a.map(&:id)
  end

  def test_output_reset_restores_the_default_value
    setup_page("<form id=f><output id=o>value</output></form>")
    el("o").value = "heya"
    el("f").reset
    assert_equal "value", el("o").value
  end

  def test_readonly_bars_any_input
    setup_page("<input id=c type=color readonly><input id=t readonly required>")
    refute el("c").will_validate
    refute el("t").will_validate
  end
end

# HTML's radio button group rule beyond checking one: becoming connected, a
# form owner change and a name change uncheck the rest of the group.
class TestRadioGroupChanges < Minitest::Test
  include DommyTestHelper

  def radio(doc, checked: true, name: "g")
    r = doc.create_element("input")
    r.type = "radio"
    r.name = name
    r.checked = checked
    r
  end

  def test_connecting_or_changing_owner_unchecks_the_group
    win = make_window("<form id=f><input type=radio name=g id=a checked></form>")
    doc = win.document
    a = doc.get_element_by_id("a")
    b = radio(doc)
    doc.get_element_by_id("f").append_child(b)
    refute a.checked
    assert b.checked

    div = doc.create_element("div")
    c = radio(doc)
    d = radio(doc)
    div.append_child(c)
    div.append_child(d)
    assert c.checked, "a detached tree with no owner change keeps both"

    renamed = radio(doc, name: "other")
    doc.get_element_by_id("f").append_child(renamed)
    renamed.set_attribute("name", "g")
    refute b.checked
  end

  def test_radio_node_list_value_setter_without_a_match_changes_nothing
    win = make_window("<form id=f><input type=radio name=r value=1 checked><input type=radio name=r value=2></form>")
    list = win.document.get_element_by_id("f").__js_get__("r")
    list.value = "nope"
    assert_equal "1", list.value
    list.value = "2"
    assert_equal "2", list.value
  end
end

# HTML's stepUp(n) / stepDown(n).
class TestInputStepping < Minitest::Test
  include DommyTestHelper

  def input(attrs)
    win = make_window("<input id=i type=number #{attrs}>")
    win.document.get_element_by_id("i")
  end

  def test_unaligned_value_snaps_in_the_step_direction
    i = input("step=2 min=1 value=4")
    i.step_up(5)
    assert_equal "5", i.value
    i.value = "4"
    i.step_down(5)
    assert_equal "3", i.value
  end

  def test_unparseable_value_starts_from_zero_and_n_is_a_long
    i = input("step=1")
    i.step_up(3)
    assert_equal "3", i.value
    # WebIDL long: 4294967295 is -1, and stepping down by -1 would move the
    # value up — against the call's direction, so nothing happens.
    i.step_down(4_294_967_295)
    assert_equal "3", i.value
  end

  def test_value_attribute_is_the_step_base_without_min
    i = input("step=2 value=1")
    refute i.validity.step_mismatch
    i.step_up
    assert_equal "3", i.value
  end
end

# Smaller HTML rules on inputs and labels.
class TestInputSmallRules < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<input id=c type=color>")
    @doc = @win.document
  end

  def test_color_values_are_parsed_as_css_colors
    c = @doc.get_element_by_id("c")
    { "crimson" => "#dc143c", "#FfF" => "#ffffff", "rgb(1,1,1)" => "#010101",
      "hsl(120, 100%, 25%)" => "#008000", "bogus" => "#000000", "#fff\u0000" => "#000000" }.each do |given, expected|
      c.value = given
      assert_equal expected, c.value, given
    end
  end

  def test_list_and_label_control_look_in_their_own_tree
    div = @doc.create_element("div")
    div.inner_html = "<input id=i list=dl><datalist id=dl></datalist><label id=l for=i></label>"
    input = div.query_selector("#i")
    assert_equal "dl", input.list&.id
    assert_same input, div.query_selector("label").control
  end

  def test_files_null_is_ignored
    f = @doc.create_element("input")
    f.type = "file"
    before = f.files
    f.__js_set__("files", nil)
    assert_same before, f.files
    assert_raises(Dommy::Bridge::TypeError) { f.__js_set__("files", []) }
  end
end
