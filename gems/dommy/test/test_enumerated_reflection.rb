# frozen_string_literal: true

require_relative "test_helper"

# The `reflect_enumerated` mechanism itself (Internal::ReflectedAttributes),
# exercised through a throwaway attribute on a real element class rather than
# any spec-defined one — the per-attribute keyword tables are
# TestEnumeratedReflection's job, in the migration commits that follow.
# `__test_demo__` follows the project's `__test_` dunder convention for
# exactly this: a method that exists only for a test to hang off of.
class TestEnumeratedReflector < Minitest::Test
  include DommyTestHelper

  class Dommy::HTMLDivElement
    reflect_enumerated __test_demo__: {
      attr: "data-test-demo", js: "__test_demo__", keywords: %w[a b],
      missing: "a", invalid: "b", empty: "a"
    }
    reflect_enumerated __test_nullable_demo__: {
      attr: "data-test-nullable-demo", js: "__test_nullable_demo__",
      keywords: %w[a], missing: nil, invalid: nil, nullable: true
    }
  end

  def setup
    @win = make_window("<div id='d'></div>")
    @div = @win.document.get_element_by_id("d")
  end

  def test_missing_reads_the_missing_default
    assert_equal("a", @div.__test_demo__)
  end

  def test_a_matched_keyword_is_returned_lowercased_and_ascii_case_insensitively
    @div.set_attribute("data-test-demo", "B")

    assert_equal("b", @div.__test_demo__)
  end

  def test_an_unrecognized_value_reads_the_invalid_default
    @div.set_attribute("data-test-demo", "bogus")

    assert_equal("b", @div.__test_demo__)
  end

  def test_an_empty_value_reads_the_empty_default_over_the_invalid_one
    @div.set_attribute("data-test-demo", "")

    assert_equal("a", @div.__test_demo__)
  end

  def test_the_setter_writes_the_attribute_unchanged
    @div.__test_demo__ = "B"

    assert_equal("B", @div.get_attribute("data-test-demo"))
    assert_equal("b", @div.__test_demo__)
  end

  def test_no_associated_keyword_is_declared_via_the_js_bridge_too
    assert_equal("a", @div.__js_get__("__test_demo__"))

    @div.__js_set__("__test_demo__", "bogus")
    assert_equal("bogus", @div.get_attribute("data-test-demo"))
  end

  # `nullable:` (a `DOMString?` attribute, e.g. `crossOrigin`): a state with no
  # keyword reads back null rather than "".
  def test_nullable_missing_and_invalid_read_null
    assert_nil(@div.__test_nullable_demo__)

    @div.set_attribute("data-test-nullable-demo", "bogus")
    assert_nil(@div.__test_nullable_demo__)
  end

  def test_nullable_setter_deletes_the_attribute_for_null
    @div.__test_nullable_demo__ = "a"
    assert(@div.has_attribute?("data-test-nullable-demo"))

    @div.__test_nullable_demo__ = nil
    refute(@div.has_attribute?("data-test-nullable-demo"))
  end

  def test_declared_type_is_enumerated_for_the_webidl_audit
    assert_equal(:enumerated, Dommy::HTMLDivElement.reflect_specs["__test_demo__"][:type])
  end
end

# Enumerated IDL attributes — HTML's "reflect ... limited to only known
# values" (§2.6.1), written entirely in prose: the specs' own IDL carries no
# [Reflect] for these at all, which is why `reflect_string` used to be wrong
# for every one of them (test/support/webidl_audit.rb's `invented_reflect_gaps`
# watches for that class of bug). What the algorithm does is checked here, per
# attribute, through both Ruby and the JS bridge; which attributes these are is
# checked against the specs' own IDL by test_webidl_conformance.rb.
# https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes
class TestEnumeratedReflection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <form id="form"></form>
      <button id="button"></button>
      <input id="input">
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  # form.method: keywords get/post/dialog, missing and invalid both "get".
  # (The Ruby accessor is `method_attr`, not `method` — that name is already
  # `Kernel#method`.)
  def test_form_method_missing_reads_the_missing_default
    assert_equal("get", el("form").method_attr)
    assert_equal("get", el("form").__js_get__("method"))
  end

  def test_form_method_canonicalizes_the_matched_keyword
    el("form").set_attribute("method", "POST")

    assert_equal("post", el("form").method_attr)
  end

  def test_form_method_invalid_reads_the_invalid_default
    el("form").set_attribute("method", "bogus")

    assert_equal("get", el("form").method_attr)
  end

  def test_form_method_setter_writes_the_attribute_unchanged
    el("form").method_attr = "post"

    assert_equal("post", el("form").get_attribute("method"))
  end

  # form.enctype / form.autocomplete: same shape, spot-checked.
  def test_form_enctype_defaults_and_canonicalizes
    assert_equal("application/x-www-form-urlencoded", el("form").enctype)

    el("form").set_attribute("enctype", "MULTIPART/FORM-DATA")
    assert_equal("multipart/form-data", el("form").enctype)

    el("form").set_attribute("enctype", "bogus")
    assert_equal("application/x-www-form-urlencoded", el("form").enctype)
  end

  def test_form_autocomplete_defaults_to_on
    assert_equal("on", el("form").autocomplete)

    el("form").set_attribute("autocomplete", "off")
    assert_equal("off", el("form").autocomplete)

    el("form").set_attribute("autocomplete", "bogus")
    assert_equal("on", el("form").autocomplete)
  end

  # button.formMethod / input.formMethod: unlike <form>'s own `method`, the
  # per-control attribute has NO missing value default — only invalid.
  def test_form_control_form_method_has_no_missing_default
    assert_equal("", el("button").form_method)
    assert_equal("", el("input").form_method)
  end

  def test_form_control_form_method_invalid_reads_get
    el("button").set_attribute("formmethod", "bogus")

    assert_equal("get", el("button").form_method)
  end

  def test_form_control_form_enctype_has_no_missing_default
    assert_equal("", el("input").form_enctype)

    el("input").set_attribute("formenctype", "bogus")
    assert_equal("application/x-www-form-urlencoded", el("input").form_enctype)
  end
end
