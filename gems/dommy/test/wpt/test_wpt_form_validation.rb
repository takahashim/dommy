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

# WPT: html/semantics/forms/the-form-element/form-nameditem.html
class TestWPTFormNamedGetter < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def form(html)
    el = @doc.create_element("form")
    el.inner_html = html
    @doc.body.append_child(el)
    el
  end

  def test_a_single_control_is_returned_directly
    f = form("<input name='a'>")
    assert_same(f.query_selector("input"), f.__js_get__("a"))
  end

  def test_several_controls_of_a_name_come_back_as_a_list
    f = form("<input type='radio' name='r' value='x'><input type='radio' name='r' value='y'>")
    list = f.__js_get__("r")
    assert_equal(2, list.length)
    assert_equal(%w[x y], list.to_a.map(&:value))
    assert_same(list, f.__js_get__("r"), "the list is [SameObject] across reads")
  end

  def test_a_control_is_reachable_by_its_id_as_well
    f = form("<input id='byid'>")
    assert_same(f.query_selector("input"), f.__js_get__("byid"))
  end

  # HTMLFormElement is [LegacyOverrideBuiltIns]: a control named after one of the
  # form's own members shadows it.
  def test_a_named_control_shadows_a_builtin
    f = form("<input name='action'><input name='length'>")
    assert_same(f.query_selector("input[name='action']"), f.__js_get__("action"))
    assert_same(f.query_selector("input[name='length']"), f.__js_get__("length"))
  end

  def test_an_unmatched_name_is_absent
    assert_equal(Dommy::Bridge::ABSENT, form("<input name='a'>").__js_get__("nope"))
  end

  # The past names map: a control that is renamed — or loses its name and id
  # entirely — stays reachable under the name it was last found by.
  def test_a_renamed_control_keeps_its_old_name
    f = form("")
    input = @doc.create_element("input")
    input.set_attribute("name", "first")
    input.set_attribute("id", "first-id")
    f.append_child(input)
    assert_same(input, f.__js_get__("first"))
    assert_same(input, f.__js_get__("first-id"))

    input.set_attribute("name", "second")
    input.set_attribute("id", "second-id")
    assert_same(input, f.__js_get__("first"))
    assert_same(input, f.__js_get__("second"))
    assert_same(input, f.__js_get__("first-id"))
    assert_same(input, f.__js_get__("second-id"))

    input.remove_attribute("name")
    input.remove_attribute("id")
    assert_same(input, f.__js_get__("first"))
    assert_same(input, f.__js_get__("second"))
  end

  def test_the_old_names_go_when_the_control_leaves_the_form
    f = form("")
    input = @doc.create_element("input")
    input.set_attribute("name", "gone")
    f.append_child(input)
    assert_same(input, f.__js_get__("gone"))
    input.remove
    assert_equal(Dommy::Bridge::ABSENT, f.__js_get__("gone"))
  end

  def test_a_name_is_only_remembered_when_it_matched_exactly_one_control
    f = form("<input type='radio' name='r'><input type='radio' name='r'>")
    f.__js_get__("r")
    f.query_selector_all("input").each { |el| el.remove_attribute("name") }
    assert_equal(Dommy::Bridge::ABSENT, f.__js_get__("r"))
  end

  def test_past_names_show_up_in_the_supported_property_names
    f = form("")
    input = @doc.create_element("input")
    input.set_attribute("name", "old")
    f.append_child(input)
    f.__js_get__("old")
    input.set_attribute("name", "new")
    assert_includes(f.__js_named_props__, "new")
    assert_includes(f.__js_named_props__, "old")
    input.remove
    refute_includes(f.__js_named_props__, "old")
  end
end

# A form containing a control named after a DOM member used to shadow that
# member for dommy's OWN reads too, because internal code went through the JS
# bridge protocol — so getElementsByTagName("form") lost any form holding an
# `<input name=prefix>`.
class TestWPTFormNamedGetterDoesNotLeakInternally < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.inner_html = "<form id='a'><input name='prefix'><input name='localName'></form><form id='b'></form>"
  end

  def test_get_elements_by_tag_name_still_finds_the_form
    assert_equal(%w[a b], @doc.get_elements_by_tag_name("form").to_a.map { |f| f.get_attribute("id") })
  end

  def test_the_named_getter_itself_still_works
    f = @doc.get_element_by_id("a")
    assert_same(f.query_selector("input[name='prefix']"), f.__js_get__("prefix"))
  end
end

# A `form` content attribute names a form BY ID IN THE ELEMENT'S OWN TREE, so
# the association never reaches out of a shadow tree — or into one.
# WPT: html/semantics/forms/the-form-element/form-elements-filter.html
class TestWPTFormOwnerTreeScope < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.inner_html = "<form id='f'><span id='inside'></span></form><span id='outside'></span>"
    @form = @doc.get_element_by_id("f")
  end

  def shadow_input(host_id, form_attr: nil)
    root = @doc.get_element_by_id(host_id).attach_shadow(mode: "open")
    input = @doc.create_element("input")
    input.set_attribute("form", form_attr) if form_attr
    root.append_child(input)
    input
  end

  def test_a_control_in_a_shadow_tree_inside_the_form_has_no_owner
    assert_nil(shadow_input("inside").form)
  end

  def test_a_form_attribute_cannot_reach_a_form_in_another_tree
    assert_nil(shadow_input("outside", form_attr: "f").form)
  end

  def test_neither_shows_up_in_the_forms_elements
    shadow_input("inside")
    shadow_input("outside", form_attr: "f")
    assert_equal(0, @form.elements.to_a.size)
  end

  def test_a_form_attribute_still_works_within_one_tree
    outside = @doc.create_element("input")
    outside.set_attribute("form", "f")
    @doc.body.append_child(outside)
    assert_same(@form, outside.form)
    assert_equal([outside], @form.elements.to_a)
  end

  # A button carries the same rule as an input.
  def test_the_rule_covers_buttons_too
    root = @doc.get_element_by_id("outside").attach_shadow(mode: "open")
    button = @doc.create_element("button")
    button.set_attribute("form", "f")
    root.append_child(button)
    assert_nil(button.form)
  end
end

# `<img>`'s `name` is obsolete but reflected — it is what puts an image in the
# document's named getter, so renaming one has to move it there.
# WPT: html/dom/documents/dom-tree-accessors/nameditem-01.html
class TestWPTImageNameReflection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<img id='a' name='b'>")
    @doc = @win.document
    @img = @doc.query_selector("img")
  end

  def test_name_reflects_the_content_attribute
    assert_equal("b", @img.name)
    @img.name = "c"
    assert_equal("c", @img.get_attribute("name"))
    assert_equal("c", @img.name)
  end

  def test_renaming_moves_the_image_in_the_documents_named_getter
    assert_same(@img, @doc.__js_get__("b"))
    @img.__js_set__("name", "c")
    assert_equal(Dommy::Bridge::ABSENT, @doc.__js_get__("b"))
    assert_same(@img, @doc.__js_get__("c"))
    assert_same(@img, @doc.__js_get__("a"), "the id keeps working")
  end

  def test_the_other_obsolete_reflections_are_there_too
    %w[align border useMap longDesc].each do |key|
      refute_equal(Dommy::Bridge::ABSENT, @img.__js_get__(key), key)
    end
    refute(@img.__js_get__("isMap"))
  end
end
