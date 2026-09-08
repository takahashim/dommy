# frozen_string_literal: true

require_relative "../test_helper"

# WPT: html/semantics/forms/constraints/form-validation-validity-patternMismatch.html
class TestWPTPatternMismatch < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def control(type, pattern, value, **attrs)
    el = @doc.create_element("input")
    el.type = type
    el.set_attribute("pattern", pattern)
    attrs.each_key { |k| el.set_attribute(k.to_s, "") }
    @doc.body.append_child(el)
    el.value = value
    el
  end

  def test_a_matching_value_does_not_mismatch
    refute(control("text", "[A-Z]{1}", "A").validity.pattern_mismatch)
  end

  def test_a_non_matching_value_mismatches
    assert(control("text", "[a-z]{3,}", "ABCD").validity.pattern_mismatch)
  end

  def test_a_partial_match_still_mismatches
    assert(control("text", "[A-Z]+", "ABC123").validity.pattern_mismatch)
  end

  def test_an_empty_value_is_never_a_mismatch
    refute(control("text", "[A-Z]+", "").validity.pattern_mismatch)
  end

  # HTML compiles the pattern as a JavaScript RegExp and ignores the attribute
  # outright when that throws, so an unparseable pattern reports no mismatch.
  def test_an_unparseable_pattern_is_ignored
    refute(control("text", "(abc", "de").validity.pattern_mismatch)
  end

  def test_a_pattern_that_escapes_its_own_group_is_ignored
    refute(control("text", "a)(b", "de").validity.pattern_mismatch)
  end

  # The `v` flag makes `(` a syntax error inside a character class, even though
  # every other regex dialect — Ruby's included — accepts `[(]` happily.
  def test_a_pattern_only_the_v_flag_rejects_is_ignored
    refute(control("text", "[(]", "x").validity.pattern_mismatch)
  end

  def test_a_nested_class_is_not_mistaken_for_a_v_flag_error
    assert(control("text", "\\u1234\\cx[5-\\[]{2}", "ሴ\x18[4").validity.pattern_mismatch)
    refute(control("text", "\\u1234\\cx[5-\\[]{2}", "ሴ\x18[6").validity.pattern_mismatch)
  end

  # A `multiple` email control holds a comma-separated list, and the pattern is
  # matched against each entry rather than against the list as a whole.
  def test_a_multiple_email_matches_the_pattern_per_entry
    refute(control("email", "[A-Z]{1}", "A,A", multiple: true).validity.pattern_mismatch)
  end

  def test_one_bad_entry_mismatches_the_whole_multiple_email
    assert(control("email", "[a-z]{3,}", "abcd,ABCD", multiple: true).validity.pattern_mismatch)
  end

  def test_the_comma_separators_are_not_part_of_what_is_matched
    assert(control("email", "a,", "a,", multiple: true).validity.pattern_mismatch)
  end

  def test_entries_are_trimmed_before_matching
    refute(control("email", "[A-Z]+", "ABC, ABC", multiple: true).validity.pattern_mismatch)
  end
end

# WPT: html/semantics/forms/constraints/form-validation-validity-stepMismatch.html
class TestWPTStepMismatch < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def number(step, value)
    el = @doc.create_element("input")
    el.type = "number"
    el.set_attribute("step", step.to_s)
    @doc.body.append_child(el)
    el.value = value
    el
  end

  def test_a_plain_multiple_matches_the_step
    refute(number(2, "4").validity.step_mismatch)
    assert(number(2, "3").validity.step_mismatch)
  end

  # The check is decimal, not binary: 3.6 is an exact multiple of 0.003 in base
  # 10, but the two IEEE-754 doubles do not divide evenly.
  def test_a_fractional_step_is_compared_in_decimal
    refute(number(0.003, "3.6").validity.step_mismatch)
  end

  def test_an_exponent_step_is_compared_in_decimal
    refute(number(1e-12, "-12345678.9").validity.step_mismatch)
  end

  # And the other direction: the float division lands exactly on an integer
  # here, so only decimal arithmetic catches the mismatch.
  def test_a_tiny_step_that_does_not_divide_is_a_mismatch
    assert(number(3e-15, "17").validity.step_mismatch)
  end
end

# WPT: html/semantics/forms/constraints/form-validation-willValidate.html
class TestWPTWillValidate < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def input(type, **attrs)
    el = @doc.create_element("input")
    el.type = type
    attrs.each_key { |k| el.set_attribute(k.to_s, "") }
    @doc.body.append_child(el)
    el
  end

  # Only the Hidden, Reset Button and Button states are barred outright.
  def test_the_barred_input_types_do_not_validate
    %w[hidden reset button].each { |type| refute(input(type).will_validate, type) }
  end

  # A submit or image button is a submittable element like any other.
  def test_a_submit_or_image_button_validates
    %w[submit image text checkbox color file].each { |type| assert(input(type).will_validate, type) }
  end

  def test_disabled_and_readonly_controls_do_not_validate
    refute(input("text", disabled: true).will_validate)
    refute(input("text", readonly: true).will_validate)
  end

  # An <object> is form-associated, so it carries the whole constraint
  # validation API — and is barred from constraint validation, so every member
  # reports the never-invalid answer.
  def test_an_object_exposes_the_api_and_never_validates
    el = @doc.create_element("object")
    @doc.body.append_child(el)
    refute(el.__js_get__("willValidate"))
    assert_equal("", el.__js_get__("validationMessage"))
    refute_equal(Dommy::Bridge::ABSENT, el.__js_get__("validity"))
    assert(el.__js_call__("checkValidity", []))
    assert_nil(el.__js_call__("setCustomValidity", ["nope"]))
    assert(el.__js_call__("checkValidity", []))
  end
end

# WPT: html/semantics/forms/constraints/form-validation-validity-customError.html
class TestWPTCustomError < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def control(tag)
    el = @doc.create_element(tag)
    @doc.body.append_child(el)
    el
  end

  def test_every_form_control_reports_its_custom_message
    %w[input button select textarea].each do |tag|
      el = control(tag)
      el.set_custom_validity("My custom error")
      assert(el.validity.custom_error, tag)
      assert_equal("My custom error", el.validation_message, tag)
      refute(el.check_validity, tag)
    end
  end

  def test_an_empty_custom_message_clears_the_error
    %w[input button select textarea].each do |tag|
      el = control(tag)
      el.set_custom_validity("My custom error")
      el.set_custom_validity("")
      refute(el.validity.custom_error, tag)
      assert_equal("", el.validation_message, tag)
      assert(el.check_validity, tag)
    end
  end

  # A control barred from constraint validation reports no message at all.
  def test_a_disabled_control_reports_no_message
    el = control("input")
    el.set_custom_validity("My custom error")
    el.disabled = true
    assert_equal("", el.validation_message)
  end
end

# The boolean IDL attributes each live on specific interfaces, so feature
# detection (`"readOnly" in control`) can tell a text control from a select.
# WPT: reached through html/semantics/forms/constraints/support/validator.js
class TestBooleanIDLAttributeSurface < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def absent?(tag, key)
    @doc.create_element(tag).__js_get__(key).equal?(Dommy::Bridge::ABSENT)
  end

  def test_read_only_belongs_to_input_and_textarea_only
    refute(absent?("input", "readOnly"))
    refute(absent?("textarea", "readOnly"))
    assert(absent?("select", "readOnly"))
    assert(absent?("button", "readOnly"))
    assert(absent?("div", "readOnly"))
  end

  def test_checked_belongs_to_input_only
    refute(absent?("input", "checked"))
    assert(absent?("select", "checked"))
    assert(absent?("div", "checked"))
  end

  def test_required_and_multiple_stay_on_their_own_interfaces
    refute(absent?("select", "required"))
    refute(absent?("select", "multiple"))
    assert(absent?("button", "required"))
    assert(absent?("textarea", "multiple"))
  end

  def test_disabled_covers_the_form_controls_plus_link_and_style
    %w[button fieldset input link optgroup option select style textarea].each do |tag|
      refute(absent?(tag, "disabled"), tag)
    end
    %w[div form span my-element].each { |tag| assert(absent?(tag, "disabled"), tag) }
  end

  def test_hidden_stays_global
    %w[div input my-element].each { |tag| refute(absent?(tag, "hidden"), tag) }
  end

  # Assigning one on an element that does not define it is an ordinary JS
  # expando, so it must not reach the content attribute.
  def test_assigning_a_foreign_boolean_does_not_set_the_attribute
    el = @doc.create_element("div")
    el.__js_set__("readOnly", true)
    refute(el.has_attribute?("readonly"))
  end
end
