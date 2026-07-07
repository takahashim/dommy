# frozen_string_literal: true

require_relative "test_helper"

class TestValidityStateFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def input_with_attrs(attrs)
    el = @doc.create_element("input")
    attrs.each { |k, v| el.set_attribute(k.to_s, v.to_s) }
    el
  end

  # ---- valueMissing ----

  def test_value_missing_when_required_and_empty
    el = input_with_attrs(required: "", value: "")
    assert(el.validity.value_missing)
    refute(el.validity.valid)
  end

  def test_value_missing_false_when_required_and_filled
    el = input_with_attrs(required: "", value: "x")
    refute(el.validity.value_missing)
    assert(el.validity.valid)
  end

  def test_value_missing_false_when_not_required
    el = input_with_attrs(value: "")
    refute(el.validity.value_missing)
  end

  def test_value_missing_for_unchecked_checkbox
    el = input_with_attrs(type: "checkbox", required: "")
    assert(el.validity.value_missing)
    el.set_attribute("checked", "")
    refute(el.validity.value_missing)
  end

  # ---- typeMismatch ----

  def test_type_mismatch_email_invalid
    el = input_with_attrs(type: "email", value: "not-an-email")
    assert(el.validity.type_mismatch)
  end

  def test_type_mismatch_email_valid
    el = input_with_attrs(type: "email", value: "user@example.com")
    refute(el.validity.type_mismatch)
  end

  def test_type_mismatch_email_empty
    el = input_with_attrs(type: "email", value: "")
    refute(el.validity.type_mismatch)
  end

  def test_type_mismatch_url_invalid
    el = input_with_attrs(type: "url", value: "not a url")
    assert(el.validity.type_mismatch)
  end

  def test_type_mismatch_url_valid_http
    el = input_with_attrs(type: "url", value: "https://example.com")
    refute(el.validity.type_mismatch)
  end

  # ---- patternMismatch ----

  def test_pattern_mismatch_invalid
    el = input_with_attrs(pattern: "[0-9]{3}", value: "abc")
    assert(el.validity.pattern_mismatch)
  end

  def test_pattern_mismatch_valid
    el = input_with_attrs(pattern: "[0-9]{3}", value: "123")
    refute(el.validity.pattern_mismatch)
  end

  def test_pattern_mismatch_partial_does_not_match
    # `pattern` is implicitly anchored ^...$.
    el = input_with_attrs(pattern: "[0-9]{3}", value: "1234")
    assert(el.validity.pattern_mismatch)
  end

  def test_pattern_mismatch_empty_value_ok
    el = input_with_attrs(pattern: "[0-9]{3}", value: "")
    refute(el.validity.pattern_mismatch)
  end

  # ---- tooLong / tooShort ----

  # tooLong / tooShort only fire when the value was changed by a USER EDIT (per
  # spec); a value set via attribute/script never triggers them.
  def test_too_long
    el = input_with_attrs(maxlength: "5", value: "123456")
    refute(el.validity.too_long)
  end

  def test_too_short
    el = input_with_attrs(minlength: "5", value: "abc")
    refute(el.validity.too_short)
  end

  def test_too_short_false_for_empty
    el = input_with_attrs(minlength: "5", value: "")
    refute(el.validity.too_short)
  end

  # ---- range / step ----

  def test_range_underflow
    el = input_with_attrs(type: "number", min: "10", value: "5")
    assert(el.validity.range_underflow)
  end

  def test_range_overflow
    el = input_with_attrs(type: "number", max: "10", value: "15")
    assert(el.validity.range_overflow)
  end

  def test_step_mismatch
    el = input_with_attrs(type: "number", min: "0", step: "5", value: "7")
    assert(el.validity.step_mismatch)
  end

  def test_step_match
    el = input_with_attrs(type: "number", min: "0", step: "5", value: "15")
    refute(el.validity.step_mismatch)
  end

  def test_step_any_disables_step_mismatch
    el = input_with_attrs(type: "number", step: "any", value: "3.7")
    refute(el.validity.step_mismatch)
  end

  # ---- customError ----

  def test_custom_error_set_via_method
    el = input_with_attrs(value: "x")
    el.set_custom_validity("custom problem")
    assert(el.validity.custom_error)
    refute(el.validity.valid)
  end

  def test_custom_error_cleared_by_empty_string
    el = input_with_attrs(value: "x")
    el.set_custom_validity("oops")
    el.set_custom_validity("")
    refute(el.validity.custom_error)
    assert(el.validity.valid)
  end

  # ---- validationMessage / willValidate ----

  def test_validation_message_for_required_empty
    el = input_with_attrs(required: "", value: "")
    assert_match(/fill out/, el.validation_message)
  end

  def test_validation_message_for_pattern
    el = input_with_attrs(pattern: "[0-9]+", value: "abc")
    assert_match(/format/, el.validation_message)
  end

  def test_validation_message_for_email
    el = input_with_attrs(type: "email", value: "x")
    assert_match(/email/i, el.validation_message)
  end

  def test_validation_message_returns_custom_when_set
    el = input_with_attrs(value: "x")
    el.set_custom_validity("nope")
    assert_equal("nope", el.validation_message)
  end

  def test_will_validate_true_for_normal_input
    el = input_with_attrs(value: "")
    assert(el.will_validate)
  end

  def test_will_validate_false_for_disabled
    el = input_with_attrs(value: "", disabled: "")
    refute(el.will_validate)
  end

  def test_will_validate_false_for_hidden_type
    el = input_with_attrs(type: "hidden", value: "")
    refute(el.will_validate)
  end

  # ---- checkValidity dispatches invalid event ----

  def test_check_validity_dispatches_invalid_when_invalid
    el = input_with_attrs(required: "", value: "")
    fired = false
    el.add_event_listener("invalid") { fired = true }
    refute(el.check_validity)
    assert(fired)
  end

  def test_check_validity_does_not_dispatch_when_valid
    el = input_with_attrs(value: "x")
    fired = false
    el.add_event_listener("invalid") { fired = true }
    assert(el.check_validity)
    refute(fired)
  end

  # ---- form.checkValidity walks controls ----

  def test_form_check_validity_returns_true_when_all_valid
    @doc.body.inner_html = "<form><input value='x'><input value='y'></form>"
    form = @doc.query_selector("form")
    assert(form.check_validity)
  end

  def test_form_check_validity_returns_false_when_any_invalid
    @doc.body.inner_html = "<form><input required value=''><input value='y'></form>"
    form = @doc.query_selector("form")
    refute(form.check_validity)
  end

  def test_form_check_validity_fires_invalid_on_failing_controls
    @doc.body.inner_html = "<form><input id='bad' required value=''></form>"
    form = @doc.query_selector("form")
    bad = @doc.get_element_by_id("bad")
    fired = false
    bad.add_event_listener("invalid") { fired = true }
    form.check_validity
    assert(fired)
  end

  # ---- textarea & select ----

  def test_textarea_value_missing
    @doc.body.inner_html = "<textarea required></textarea>"
    ta = @doc.query_selector("textarea")
    assert(ta.validity.value_missing)
  end

  def test_select_value_missing
    @doc.body.inner_html = "<select required><option value=''></option><option value='x'>X</option></select>"
    sel = @doc.query_selector("select")
    assert(sel.validity.value_missing)
  end
end
