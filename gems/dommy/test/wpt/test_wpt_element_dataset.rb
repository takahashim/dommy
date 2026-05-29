# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Element.dataset (HTMLOrForeignElement mixin).
# WPT: html/dom/elements/global-attributes/dataset-*.html
# Spec: https://html.spec.whatwg.org/multipage/dom.html#dom-dataset
#
# dataset is a proxy whose property names are camelCase versions of
# `data-*` attribute names. Reading a property looks up the
# corresponding kebab-case attribute; writing a property sets it.
# Existing test/test_mutation_observer_attrs.rb exercises dataset
# only as a MutationObserver trigger, leaving the mapping rules
# uncovered.

class TestWPTDatasetGetter < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @el = @win.document.create_element("div")
  end

  def test_read_simple_data_attribute
    @el.set_attribute("data-foo", "bar")
    assert_equal("bar", @el.dataset.__js_get__("foo"))
  end

  def test_read_kebab_case_returns_camelcase
    @el.set_attribute("data-user-name", "alice")
    assert_equal("alice", @el.dataset.__js_get__("userName"))
  end

  def test_missing_property_returns_nil
    assert_nil(@el.dataset.__js_get__("missing"))
  end

  def test_non_data_attribute_not_exposed
    @el.set_attribute("class", "main")
    assert_nil(@el.dataset.__js_get__("class"))
  end
end

class TestWPTDatasetSetter < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @el = @win.document.create_element("div")
  end

  def test_set_writes_data_attribute
    @el.dataset.__js_set__("foo", "bar")
    assert_equal("bar", @el.get_attribute("data-foo"))
  end

  def test_set_camelcase_writes_kebab_case_attribute
    @el.dataset.__js_set__("userName", "alice")
    assert_equal("alice", @el.get_attribute("data-user-name"))
  end

  def test_set_overrides_existing_value
    @el.set_attribute("data-foo", "old")
    @el.dataset.__js_set__("foo", "new")
    assert_equal("new", @el.get_attribute("data-foo"))
  end
end
