# frozen_string_literal: true

module Dommy
  module Internal
    # Computes the ARIA state/property set an accessibility tree exposes for an
    # element, given its already-computed role. Returns a compact hash holding
    # only the states meaningful for that role, in a fixed key order so an ARIA
    # snapshot serializes deterministically:
    #
    #   checked, disabled, expanded, level, pressed, readonly, required, selected
    #
    # Each value is `true`, `false`, `"mixed"`, or (for level) an Integer. A
    # state native to the host language (an <input>'s checked/disabled, an
    # <option>'s selected, a <details>'s open) wins; otherwise the matching
    # `aria-*` attribute is read (tri-state where ARIA allows it).
    module AriaState
      CHECKABLE = %w[checkbox radio menuitemcheckbox menuitemradio switch treeitem].freeze
      SELECTABLE = %w[option tab row gridcell treeitem columnheader rowheader].freeze
      READONLY_ROLES = %w[textbox searchbox spinbutton combobox gridcell columnheader rowheader].freeze
      REQUIRED_ROLES = %w[textbox searchbox spinbutton combobox listbox radiogroup checkbox].freeze

      module_function

      def compute(element, role)
        states = {}
        add(states, :checked, checked_state(element)) if CHECKABLE.include?(role)
        add(states, :disabled, disabled_state(element))
        add(states, :expanded, expanded_state(element))
        add(states, :level, role == "heading" ? AriaRole.heading_level(element) : nil)
        add(states, :pressed, tristate(element, "aria-pressed")) if role == "button"
        add(states, :readonly, readonly_state(element)) if READONLY_ROLES.include?(role)
        add(states, :required, required_state(element)) if REQUIRED_ROLES.include?(role)
        add(states, :selected, selected_state(element)) if SELECTABLE.include?(role)
        states
      end

      def add(states, key, value)
        states[key] = value unless value.nil?
      end

      # checkbox/radio: an indeterminate native control is "mixed"; otherwise
      # the native checkedness, else the tri-state aria-checked.
      def checked_state(element)
        return "mixed" if element.respond_to?(:indeterminate) && element.indeterminate
        return element.checked if native_checkbox_radio?(element)

        tristate(element, "aria-checked")
      end

      def selected_state(element)
        return option_selected?(element) if native_option?(element)

        tristate(element, "aria-selected")
      end

      # An <option>'s effective selectedness. In a single-selection <select>
      # only one option is selected — the last bearing the `selected` attribute,
      # or the first option when none does — so the attribute alone (which Dommy
      # reflects) over-reports. A multiple select selects every marked option.
      def option_selected?(option)
        select = option.respond_to?(:closest) ? option.closest("select") : nil
        return !!option.selected unless select
        return option.has_attribute?("selected") if select.respond_to?(:multiple) && select.multiple

        same_node?(option, single_selected_option(select))
      end

      def single_selected_option(select)
        options = select.options.to_a
        options.reverse_each.find { |o| o.has_attribute?("selected") } || options.first
      end

      def same_node?(first, second)
        second && first.__dommy_backend_node__ == second.__dommy_backend_node__
      end

      # Expanded comes only from aria-expanded. A native <details open> is NOT
      # reported as expanded (Playwright / Chromium put no expanded state on the
      # details group).
      def expanded_state(element)
        tristate(element, "aria-expanded")
      end

      # Form controls whose `disabled` content attribute is meaningful but which
      # do not (all) expose a reflected `disabled` IDL property in Dommy.
      DISABLEABLE_TAGS = %w[button fieldset input optgroup option select textarea].freeze

      # disabled / readonly / required are binary (no "[disabled=false]"): return
      # true or nil so the caller omits the key when absent.
      def disabled_state(element)
        true if native_disabled?(element) || aria_true?(element, "aria-disabled")
      end

      # Native disabledness: the reflected property when present (input/option/
      # optgroup), else the content attribute on a disable-able control.
      def native_disabled?(element)
        return element.disabled if element.respond_to?(:disabled)

        DISABLEABLE_TAGS.include?(element.local_name.to_s.downcase) && element.has_attribute?("disabled")
      end

      def readonly_state(element)
        true if (element.respond_to?(:readonly) && element.readonly) || aria_true?(element, "aria-readonly")
      end

      def required_state(element)
        true if (element.respond_to?(:required) && element.required) || aria_true?(element, "aria-required")
      end

      def tristate(element, attribute)
        case element.get_attribute(attribute).to_s.downcase
        when "true" then true
        when "false" then false
        when "mixed" then "mixed"
        end
      end

      def aria_true?(element, attribute) = element.get_attribute(attribute).to_s.casecmp?("true")

      def native_checkbox_radio?(element)
        element.respond_to?(:checked) && tag?(element, "input") &&
          %w[checkbox radio].include?(element.get_attribute("type").to_s.downcase)
      end

      def native_option?(element) = element.respond_to?(:selected) && tag?(element, "option")
      def tag?(element, name) = element.local_name.to_s.casecmp?(name)
    end
  end
end
