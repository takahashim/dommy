# frozen_string_literal: true

require_relative "../test_helper"

# `module_function` publishes every method a module defines, so each of these
# modules closes the ones that are only how it works with private_class_method.
# That list is written by hand, which means it goes stale the moment someone
# adds a method and forgets — this test is what notices.
#
# A new public method here is either API, and belongs in the table below with a
# caller to justify it, or it is not, and belongs behind private_class_method.
class TestInternalModuleApi < Minitest::Test
  API = {
    Dommy::Internal::AccessibleName => %w[compute referenced_names block_level?],
    Dommy::Internal::AccessibleDescription => %w[compute],
    Dommy::Internal::AccessibilityTree => %w[build],
    Dommy::Internal::AccessibilityVisibility => %w[hidden? hidden_for_name?],
    Dommy::Internal::AriaRole => %w[compute heading_level],
    Dommy::Internal::AriaSnapshot => %w[serialize],
    Dommy::Internal::AriaState => %w[compute],
    Dommy::Internal::BackendPrefilter => %w[
      each_backend_descendant static_prefilters prefilter_for
      exact_class_or_id_prefilter backend_passes? backend_root_of document_of
    ],
    Dommy::Internal::ElementState => %w[
      html_element? html_document? enableable_element? disabled_element?
      constraint_invalid? constraint_valid? form_control_required?
      form_control_optional? read_only_element? read_write_element?
      dir_match? lang_match? link_element?
    ],
    Dommy::Internal::InsertionPoint => %w[count previous_sibling skip_args skip_args_backwards surviving_anchor],
    Dommy::Internal::NodeIdentity => %w[same_node? key_for],
    Dommy::Internal::TextFlattening => %w[squish],
  }.freeze

  def test_each_module_publishes_only_its_api
    unexpected = API.filter_map do |mod, api|
      extra = (mod.singleton_methods(false).map(&:to_s) - api).sort
      "#{mod}: #{extra.join(", ")}" unless extra.empty?
    end
    assert_empty unexpected,
      "public but not API — add a private_class_method, or list it here with the caller that needs it"
  end

  def test_each_listed_method_exists
    missing = API.filter_map do |mod, api|
      absent = api.reject { |name| mod.respond_to?(name) }
      "#{mod}: #{absent.join(", ")}" unless absent.empty?
    end
    assert_empty missing, "listed as API but not defined"
  end
end
