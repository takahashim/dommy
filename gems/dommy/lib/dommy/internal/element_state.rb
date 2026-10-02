# frozen_string_literal: true

require_relative "directionality"
require_relative "element_editing"

module Dommy
  module Internal
    # What the state pseudo-classes ask an element: is it disabled, does it
    # satisfy its constraints, is it editable, does its language match.
    #
    # These are HTML's rules, not the selector engine's — SelectorMatcher only
    # needs to know which pseudo-class maps to which question. They lived inside
    # it, which made a 960-line file where the HTML semantics and the matching
    # algorithm were one module.
    module ElementState
      module_function

      def html_element?(element)
        element.namespace_uri == Namespaces::HTML
      end

      # Case-insensitive matching applies in an HTML document (text/html). Delegate
      # to the document's own cheap flag (`@content_type == "text/html"`) instead
      # of re-deriving it with `content_type.downcase.include?("html")` on every
      # element — that string work showed up across millions of match calls. (It
      # also fixes XHTML, which is genuinely case-sensitive.)
      def html_document?(element)
        doc = element.owner_document
        !doc.nil? && doc.html_document?
      end

      def enableable_element?(element)
        %w[button input select textarea optgroup option fieldset].include?(element.local_name.to_s.downcase)
      end

      # A candidate for constraint validation: a form-associated control whose
      # `willValidate` is true (not disabled / readonly / barred).
      def validation_candidate?(element)
        element.respond_to?(:will_validate) && element.respond_to?(:validity) && element.will_validate
      end

      # `:invalid` / `:valid` apply to candidates (by their validity) and to a
      # form / fieldset (by whether any descendant candidate is invalid).
      def constraint_invalid?(element)
        name = element.local_name.to_s.downcase
        if %w[form fieldset].include?(name)
          descendant_candidates(element).any? { |c| !c.validity.valid }
        else
          validation_candidate?(element) && !element.validity.valid
        end
      end

      def constraint_valid?(element)
        name = element.local_name.to_s.downcase
        if %w[form fieldset].include?(name)
          descendant_candidates(element).all? { |c| c.validity.valid }
        else
          validation_candidate?(element) && element.validity.valid
        end
      end

      def descendant_candidates(element)
        element.query_selector_all("input, select, textarea, button").select do |c|
          validation_candidate?(c)
        end
      end

      # `:required` / `:optional` apply to input / select / textarea per the
      # `required` attribute.
      def requirable_element?(element)
        %w[input select textarea].include?(element.local_name.to_s.downcase)
      end

      def form_control_required?(element)
        requirable_element?(element) && element.__internal_has_attribute__?("required")
      end

      def form_control_optional?(element)
        requirable_element?(element) && !element.__internal_has_attribute__?("required")
      end

      # `:read-write` matches an editable control (a mutable text input / textarea,
      # or an element with contenteditable); `:read-only` is its complement over
      # the elements the pseudo-classes apply to.
      def read_write_element?(element)
        name = element.local_name.to_s.downcase
        if name == "textarea"
          return !element.__internal_has_attribute__?("readonly") && !disabled_element?(element)
        end
        if name == "input"
          return false unless mutable_input_type?(element)

          return !element.__internal_has_attribute__?("readonly") && !disabled_element?(element)
        end
        editable_via_contenteditable?(element)
      end

      def read_only_element?(element)
        name = element.local_name.to_s.downcase
        return !read_write_element?(element) if %w[input textarea].include?(name)

        # For other elements, :read-only matches when not editable.
        !editable_via_contenteditable?(element)
      end

      # Text-like input types that can be read-write (not button/checkbox/etc.).
      def mutable_input_type?(element)
        %w[text search url tel email password date month week time
           datetime-local number range color].include?(
             (element.__internal_attribute_value__("type") || "text").to_s.downcase
           )
      end

      def editable_via_contenteditable?(element)
        ElementEditing.editable?(element)
      end

      def disabled_element?(element)
        return true if element.__internal_has_attribute__?("disabled")

        if element.local_name.to_s.downcase == "option"
          parent = element.parent_element
          return true if parent&.local_name.to_s.downcase == "optgroup" && parent.__internal_has_attribute__?("disabled")
        end
        fieldset_disabled?(element)
      end

      def fieldset_disabled?(element)
        parent = element.parent_element
        while parent
          if parent.local_name.to_s.downcase == "fieldset" && parent.__internal_has_attribute__?("disabled")
            # A control inside the fieldset's FIRST legend is not disabled by
            # THIS fieldset, but an outer disabled fieldset can still disable it.
            legend = first_legend_child(parent)
            return true unless legend && contains_element?(legend, element)
          end

          parent = parent.parent_element
        end
        false
      end

      def first_legend_child(fieldset)
        fieldset.children.to_a.find { |child| child.local_name.to_s.downcase == "legend" }
      end

      def contains_element?(ancestor, element)
        node = element
        while node
          return true if node.equal?(ancestor)

          node = node.parent_element
        end
        false
      end

      # `:lang()` accepts a list of language ranges; the element's language
      # must extended-filter-match any of them (RFC 4647 §3.3.2 — so `de-DE`
      # matches `de-Latn-DE`). An unknown language (`lang=""`) matches none.
      def lang_match?(element, ranges)
        actual = language_of(element)
        return false if actual.nil? || actual.empty?

        actual = actual.downcase
        Array(ranges).any? { |range| lang_range_match?(actual, range.to_s.downcase) }
      end

      # The namespaces whose elements take a `lang` attribute in no namespace.
      LANG_NAMESPACES = [Namespaces::HTML, Namespaces::SVG, Namespaces::MATHML].freeze

      # HTML "the language of a node": the nearest element's `xml:lang` (in
      # the XML namespace), or else its `lang` in no namespace when it is an
      # HTML, SVG or MathML element; "" when that value is empty (the
      # language is unknown, and no ancestor is asked), nil when none says.
      def language_of(element)
        node = element
        while node
          value = Backend.get_attribute_ns(node.__dommy_backend_node__, Namespaces::XML, "lang")
          value = node.__internal_attribute_value__("lang") if value.nil? && LANG_NAMESPACES.include?(node.namespace_uri)
          return value unless value.nil?

          node = node.parent_element
        end
        nil
      end

      def lang_range_match?(actual, range)
        return false if range.empty?
        return true if range == "*"

        tags = actual.split("-")
        subs = range.split("-")
        return false unless subs[0] == "*" || tags[0] == subs[0]

        i = 1
        j = 1
        while j < subs.length
          if subs[j] == "*"
            j += 1
          elsif i >= tags.length
            return false
          elsif tags[i] == subs[j]
            i += 1
            j += 1
          elsif tags[i].length == 1
            # A singleton subtag (e.g. "x") ends the matchable prefix.
            return false
          else
            i += 1
          end
        end
        true
      end

      # `:link` / `:any-link` match an `a` or `area` with an href. A `<link href>`
      # is not a hyperlink for selector purposes, however much its name suggests
      # otherwise.
      def link_element?(element)
        %w[a area].include?(element.local_name.to_s.downcase) && element.__internal_has_attribute__?("href")
      end

      # `:dir()` — the element's computed directionality, from the `dir`
      # attribute (including the auto heuristic) or inheritance.
      def dir_match?(element, argument)
        expected = Array(argument).first.to_s.downcase
        return false unless %w[ltr rtl].include?(expected)

        Directionality.direction_of(element) == expected
      end

      # Everything above is the module; everything below is how.
      private_class_method :validation_candidate?
      private_class_method :descendant_candidates
      private_class_method :requirable_element?
      private_class_method :mutable_input_type?
      private_class_method :editable_via_contenteditable?
      private_class_method :fieldset_disabled?
      private_class_method :first_legend_child
      private_class_method :contains_element?
      private_class_method :lang_range_match?
      private_class_method :language_of
    end
  end
end
