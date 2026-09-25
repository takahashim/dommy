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
