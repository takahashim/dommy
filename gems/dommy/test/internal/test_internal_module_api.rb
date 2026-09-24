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

  # The mixins Element and Document are assembled from. A method extracted into
  # a mixin loses whatever `private` it sat under in the class it came from, so
  # the extraction that created these modules published two methods nobody
  # meant to publish (Element#toggle_popover_state and #record_scroll) and
  # nothing noticed: comparing public methods before and after an extraction
  # does not see a method that was there all along, only private.
  #
  # This is the surface as it stood before the extraction. Something new here
  # is either API, and goes in the list, or belongs under the module's
  # `private`.
  MIXIN_API = {
    Dommy::Internal::ElementTopLayer => %w[request_fullscreen show_popover hide_popover toggle_popover],
    Dommy::Internal::ElementGeometry => %w[
      get_bounding_client_rect get_client_rects __test_scroll_log__
      __internal_approx_box approximate_layout?
    ],
    Dommy::Internal::ElementShadow => %w[slot slot= assigned_slot attach_shadow shadow_root __internal_shadow_root__],
    Dommy::Internal::ElementAria => %w[
      role role= computed_role computed_label computed_description aria_snapshot
      aria_element_get aria_element_set aria_elements_get aria_elements_set
      aria_elements_current aria_find_in_root aria_ref_in_valid_scope?
    ],
    Dommy::Internal::DocumentGenerations => %w[
      style_generation dom_generation tree_generation
      __internal_bump_style_generation__ __internal_bump_dom_generation__
      __internal_note_tree_mutation__ __internal_note_attribute_mutation__
      __internal_note_character_data_mutation__ __internal_note_value_change__
      __internal_note_selector_state_change__ __internal_style_value_sensitive__
      __internal_style_affected_by_attribute__ __internal_style_text_sensitive__
      __internal_inside_style_element__ __internal_direction_sensitive__
      __internal_direction_sensitive_ancestor__
    ],
    Dommy::Internal::DocumentLiveRanges => %w[
      __internal_register_range__ __internal_each_live_range__ live_ranges?
      __internal_ranges_normalize_merge__ __internal_ranges_split_text__
      __internal_ranges_will_insert__ live_ranges_where child_index_of_wrapper
    ],
    Dommy::Internal::DocumentInteractionState => %w[
      active_element __internal_set_active_element__ __internal_focused_element__
      __internal_hovered_element__ __internal_set_hovered_element__
    ],
  }.freeze

  def test_each_mixin_publishes_only_its_api
    unexpected = MIXIN_API.filter_map do |mod, api|
      extra = (mod.public_instance_methods(false).map(&:to_s) - api).sort
      "#{mod}: #{extra.join(", ")}" unless extra.empty?
    end
    assert_empty unexpected,
      "public but not API — move it under the module's `private`, or list it here"
  end

  def test_each_listed_mixin_method_exists
    missing = MIXIN_API.filter_map do |mod, api|
      absent = api.reject { |name| mod.method_defined?(name) || mod.private_method_defined?(name) }
      "#{mod}: #{absent.join(", ")}" unless absent.empty?
    end
    assert_empty missing, "listed as API but not defined"
  end

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
