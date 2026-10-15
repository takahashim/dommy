# frozen_string_literal: true

require_relative "../test_helper"
require "dommy/internal/element_matching"

# Each of these modules defines its functions in `class << self`, the ones
# other code calls above `private` and the ones that are only how it works
# below. A method defined on the wrong side of that line still works, so
# nothing but this test notices it.
#
# A new public method here is either API, and belongs in the table below with a
# caller to justify it, or it is not, and belongs under `private`.
class TestInternalModuleApi < Minitest::Test
  API = {
    Dommy::Internal::AccessibleName => %w[compute referenced_names block_level?],
    Dommy::Internal::AccessibleDescription => %w[compute],
    Dommy::Internal::AccessibilityTree => %w[build],
    Dommy::Internal::AccessibilityVisibility => %w[hidden? hidden_for_name?],
    Dommy::Internal::AriaRole => %w[compute heading_level],
    Dommy::Internal::AriaSnapshot => %w[serialize],
    Dommy::Internal::AriaState => %w[compute],
    Dommy::Internal::Autofill => %w[idl_exposed_value],
    Dommy::Internal::BackendPrefilter => %w[
      each_backend_descendant static_prefilters prefilter_for
      exact_class_or_id_prefilter backend_passes? backend_root_of document_of
    ],
    Dommy::Internal::CSS::Counters => %w[build substitute],
    Dommy::Internal::CssSyntax => %w[
      preprocess valid_escape_at? ident_start_code_point? name_code_point? atom_end bad_token_at?
    ],
    Dommy::Internal::CSS::CustomProperties => %w[contains_var? resolve_declared substitute split_args],
    Dommy::Internal::CSS::MediaQuery => %w[match?],
    Dommy::Internal::Directionality => %w[direction_of text_dependent? reflected_dir auto_directionality_form_associated?],
    Dommy::Internal::ElementEditing => %w[state editable?],
    Dommy::Internal::ElementState => %w[
      html_element? html_document? enableable_element? disabled_element?
      constraint_invalid? constraint_valid? form_control_required?
      form_control_optional? read_only_element? read_write_element?
      dir_match? lang_match? link_element? has_focus? focus_visible? focus_within? popover_open? open_element? modal_element? fullscreen_element? defined_element? custom_state?
    ],
    Dommy::Internal::Focusability => %w[
      focusable_area? sequentially_focusable? tabindex_value editing_host?
      delegates_focus? being_rendered? inert? focusable_area_for
      focus_delegate autofocus_delegate run_focusing_steps run_unfocusing_steps
      flat_tree_parent shadow_including_inclusive_ancestor?
    ],
    Dommy::Internal::Infra => %w[ascii_lowercase ascii_whitespace? split_on_ascii_whitespace],
    Dommy::Internal::LightDismiss => %w[run],
    Dommy::Internal::SequentialFocusNavigation => %w[navigate],
    Dommy::Internal::InsertionPoint => %w[convert_nodes_into_a_node count previous_sibling skip_args skip_args_backwards surviving_anchor],
    Dommy::Internal::LiteralLookup => %w[element_by_id class_tokens elements_with_classes elements_named],
    Dommy::Internal::NodeIdentity => %w[same_node? key_for],
    Dommy::Internal::RenderedText::Fragment => %w[set_inner set_outer],
    Dommy::Internal::TextFlattening => %w[squish],
    Dommy::Internal::ChildNavigable => %w[
      matches_about_blank? without_fragment window_for_response window_for_local_url error_window text_window
    ],
    Dommy::Internal::CSS::Calc => %w[evaluate],
    Dommy::Internal::CSS::Cascade => %w[computed_style author_css? index_for counter_values],
    Dommy::Internal::CSS::Color => %w[normalize extract],
    Dommy::Internal::CSS::Parser => %w[parse parse_block property_name valid_declaration_value?],
    Dommy::Internal::CSS::PropertyRegistry => %w[
      known? expansion_targets inherited? initial expand computed_value resolve_length evaluate_calc format_px
    ],
    Dommy::Internal::CSS::Renderability => %w[not_rendered?],
    Dommy::Internal::CSS::Supports => %w[match? supports_declaration?],
    Dommy::Internal::CSS::UAStylesheet => %w[rules element_declarations],
    Dommy::Internal::CSSRuleText => %w[split_rules split_rule at_keyword],
    Dommy::Internal::ElementMatching => %w[find_links find_forms find_selects find_checkable_fields field_labels],
    Dommy::Internal::EventHandlers => %w[idl_attribute_names idl_attribute? event_type attribute_changed activate_parsed],
    Dommy::Internal::ExceptionReport => %w[error_value source_position report_at thrown_host_error host_form],
    Dommy::Internal::GlobalFunctions => %w[encode_uri_component decode_uri_component btoa atob],
    Dommy::Internal::IdlReflection => %w[expected install_all!],
    Dommy::Internal::JsNumber => %w[to_string],
    Dommy::Internal::MimeType => %w[xml? charset_of with_charset],
    Dommy::Internal::Namespaces => %w[
      valid_attribute_local_name? valid_element_local_name? valid_doctype_name? validate_and_extract
    ],
    Dommy::Internal::NodeEquality => %w[equal?],
    Dommy::Internal::Referrer => %w[request_referrer request_policy header_value],
    Dommy::Internal::SelectorMatcher => %w[
      matches? query query_first closest prefilter_proves? matches_type? matches_attribute?
      matches_pseudo_class? relative_candidates nth_match? element_siblings element_descendants
    ],
    Dommy::Internal::SelectorParser => %w[parse! validate! valid?],
    Dommy::Internal::SlotAssignment => %w[
      slot_node? slottable? slot_nodes slottable_name first_slots_by_name find_slot find_slottables
      manual_slottables slottable_named? same_node?
    ],
    Dommy::Internal::UnsafeHtml => %w[run_scripts? set parse_document],
    Dommy::Internal::WebIDL => %w[
      interface! boolean node! unsigned_long unsigned_short long nullable_node! unrestricted_double
      to_number dom_string nullable_object! date_time_value
    ],
    Dommy::Internal::XmlSerialization => %w[serialize serialize_children_of copy_map],
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
    Dommy::Internal::ElementTopLayer => %w[request_fullscreen],
    Dommy::Internal::ElementPopover => %w[
      show_popover hide_popover toggle_popover __js_call__ __internal_hide_popover__
      __internal_popover_opened_mode__ __internal_popover_showing__? __internal_popover_trigger__
      __internal_popover_valid__? __internal_show_popover__ __internal_popover_removed__ __internal_attribute_changed__
    ],
    Dommy::Internal::ElementGeometry => %w[
      get_bounding_client_rect get_client_rects __test_scroll_log__
      __internal_approx_box approximate_layout?
    ],
    Dommy::Internal::ElementShadow => %w[slot slot= assigned_slot attach_shadow shadow_root __internal_shadow_root__ __internal_attach_shadow_root__],
    Dommy::Internal::ElementNonce => %w[nonce nonce= __internal_cloning_state__ __internal_apply_cloning_state__],
    Dommy::Internal::ElementCSSInlineStyle => %w[style style=],
    Dommy::Internal::SVGURIReference => %w[href href=],
    Dommy::Internal::HTMLOrSVGOrMathMLElement => %w[dataset tab_index default_tab_index focus blur __js_call__],
    Dommy::Internal::ElementAria => %w[
      role role= computed_role computed_label computed_description aria_snapshot
      aria_element_get aria_element_set aria_elements_get aria_elements_set
      aria_elements_current aria_find_in_root aria_ref_in_valid_scope?
      __internal_aria_associated_elements__
    ],
    Dommy::Internal::DocumentGenerations => %w[
      style_generation dom_generation tree_generation
      __internal_bump_style_generation__ __internal_bump_dom_generation__
      __internal_note_tree_mutation__ __internal_note_attribute_mutation__
      __internal_note_character_data_mutation__ __internal_note_value_change__
      __internal_note_selector_state_change__ __internal_style_value_sensitive__
      __internal_style_affected_by_attribute__ __internal_style_text_sensitive__
      __internal_inside_style_element__ __internal_direction_sensitive__
      __internal_direction_sensitive_ancestor__ __internal_selector_index_generation__
    ],
    Dommy::Internal::DocumentLiveRanges => %w[
      __internal_register_range__ __internal_each_live_range__ live_ranges? __internal_hand_over_ranges__
      __internal_ranges_normalize_merge__ __internal_ranges_split_text__
      __internal_ranges_will_insert__ live_ranges_where child_index_of_wrapper
    ],
    Dommy::Internal::DocumentInteractionState => %w[
      active_element __internal_set_active_element__ __internal_focused_element__
      __internal_hovered_element__ __internal_set_hovered_element__
      __internal_focus_update__ __internal_focused_subtree_removed__
      __internal_add_modal_dialog__ __internal_remove_modal_dialog__ __internal_blocking_modal_dialog__
      __internal_autofocus_inserted__ __internal_add_autofocus_candidate__ __internal_autofocus_processed__
      __internal_autofocus_done__ __internal_top_document__ __internal_schedule_rendering_update__
      __internal_open_dialogs__ __internal_add_open_dialog__ __internal_remove_open_dialog__
      __internal_popover_pointerdown_target__ __internal_popover_pointerdown_target__=
      __internal_dialog_pointerdown_target__ __internal_dialog_pointerdown_target__=
      __internal_sequential_focus_navigation_starting_point__
      __internal_sequential_focus_navigation_starting_point__=
      __internal_with_focus_type__ __internal_focus_visible__? __internal_indicate_focus__
      __internal_note_keyboard_input__ __internal_note_pointer_input__
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
      "public but not API — move it under `private`, or list it here with the caller that needs it"
  end

  def test_each_listed_method_exists
    missing = API.filter_map do |mod, api|
      absent = api.reject { |name| mod.respond_to?(name) }
      "#{mod}: #{absent.join(", ")}" unless absent.empty?
    end
    assert_empty missing, "listed as API but not defined"
  end
end
