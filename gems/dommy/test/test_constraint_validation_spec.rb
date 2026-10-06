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
