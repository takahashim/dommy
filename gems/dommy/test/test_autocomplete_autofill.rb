# frozen_string_literal: true

require_relative "test_helper"

# `<input>` / `<textarea>` / `<select>`'s `autocomplete` IDL attribute
# ([ReflectSetter], form-control-infrastructure §4.10.19.7.1): the setter
# reflects the content attribute verbatim, but the getter is the element's
# "IDL-exposed autofill value" from the autofill processing model
# (Internal::Autofill), not the raw attribute.
class TestAutocompleteAutofill < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <input id='i'>
      <input id='hidden' type='hidden'>
      <textarea id='t'></textarea>
      <select id='s'></select>
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  # A missing attribute is not "on": the algorithm's Default branch sets the
  # IDL-exposed value to the empty string regardless of a form owner.
  def test_missing_attribute_reads_as_empty_string
    assert_equal("", el("i").autocomplete)
    assert_equal("", el("t").autocomplete)
    assert_equal("", el("s").autocomplete)
  end

  def test_off_and_on_keywords
    el("i").set_attribute("autocomplete", "off")
    assert_equal("off", el("i").autocomplete)

    el("i").set_attribute("autocomplete", "ON")
    assert_equal("on", el("i").autocomplete)
  end

  def test_an_unrecognized_token_reads_as_empty_string
    el("i").set_attribute("autocomplete", "bogus")
    assert_equal("", el("i").autocomplete)
  end

  # The field name itself is copied through verbatim (only "section-*" gets
  # lowercased), but the setter always reflects the attribute as written.
  def test_a_plain_field_name_is_returned_as_written
    el("i").set_attribute("autocomplete", "Current-Password")
    assert_equal("Current-Password", el("i").autocomplete)
    assert_equal("Current-Password", el("i").get_attribute("autocomplete"))
  end

  def test_shipping_and_billing_prefix_any_field
    el("t").set_attribute("autocomplete", "shipping street-address")
    assert_equal("shipping street-address", el("t").autocomplete)
  end

  # home/work/mobile/fax/pager only prefix a Contact field (tel/email/impp);
  # canonicalized to lowercase regardless of how the attribute wrote it.
  def test_contact_kind_prefixes_a_contact_field
    el("i").set_attribute("autocomplete", "HOME tel")
    assert_equal("home tel", el("i").autocomplete)
  end

  def test_contact_kind_is_ignored_before_a_normal_field
    el("i").set_attribute("autocomplete", "home name")
    assert_equal("", el("i").autocomplete)
  end

  def test_section_prefix_is_lowercased
    el("s").set_attribute("autocomplete", "SECTION-Blue shipping street-address")
    assert_equal("section-blue shipping street-address", el("s").autocomplete)
  end

  def test_too_many_tokens_for_the_field_reads_as_empty_string
    el("i").set_attribute("autocomplete", "one two three name")
    assert_equal("", el("i").autocomplete)
  end

  # webauthn is a Credential field that can trail a Normal or Contact field.
  def test_webauthn_alone_is_valid
    el("i").set_attribute("autocomplete", "webauthn")
    assert_equal("webauthn", el("i").autocomplete)
  end

  def test_webauthn_trailing_a_field_folds_it_in
    el("i").set_attribute("autocomplete", "current-password webauthn")
    assert_equal("current-password webauthn", el("i").autocomplete)
  end

  # An input whose type is Hidden wears the "autofill anchor mantle", under
  # which a bare "on"/"off" is not a valid keyword.
  def test_hidden_input_rejects_bare_on_and_off
    el("hidden").set_attribute("autocomplete", "off")
    assert_equal("", el("hidden").autocomplete)

    el("hidden").set_attribute("autocomplete", "on")
    assert_equal("", el("hidden").autocomplete)
  end

  def test_hidden_input_still_accepts_an_autofill_detail_token
    el("hidden").set_attribute("autocomplete", "transaction-amount")
    assert_equal("transaction-amount", el("hidden").autocomplete)
  end

  def test_js_bridge_reads_and_writes_through_the_same_property
    el("i").__js_set__("autocomplete", "shipping email")
    assert_equal("shipping email", el("i").__js_get__("autocomplete"))
    assert_equal("shipping email", el("i").get_attribute("autocomplete"))
  end
end
