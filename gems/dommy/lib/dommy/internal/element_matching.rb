# frozen_string_literal: true

require_relative "dom_matching"

module Dommy
  module Internal
    # Element-type-specific finders for links, forms, selects, and
    # checkable fields.  Lives in dommy core so that companion gems
    # (currently dommy-rails) share a single finder implementation
    # instead of re-implementing the selector / filter logic per gem.
    #
    # Attribute criteria (`href:`, `action:`, `name:`) accept a String
    # (exact match), a Regexp, or any object responding to `matches?` —
    # the extension point dommy-rails uses to inject URL normalization.
    module ElementMatching
      module_function

      # Find <a> elements matching the given criteria.
      def find_links(scope, text: nil, href: nil)
        links = scope.query_selector_all("a[href]").to_a
        links = links.select { |el| DomMatching.text_matches?(el.text_content, text) } if text
        links = links.select { |el| attribute_matches?(el, "href", href) } if href
        links
      end

      # Find <form> elements matching the given criteria.  `method:` is
      # matched against the effective method, honoring a hidden
      # `_method` override field inside POST forms.
      def find_forms(scope, action: nil, method: nil)
        forms = scope.query_selector_all("form").to_a
        forms = forms.select { |el| attribute_matches?(el, "action", action) } if action
        forms = forms.select { |el| form_method_matches?(el, method) } if method
        forms
      end

      # Find <select> elements matching the given criteria.
      def find_selects(scope, name: nil, label: nil)
        selects = scope.query_selector_all("select").to_a
        selects = selects.select { |el| attribute_matches?(el, "name", name) } if name
        selects = selects.select { |el| field_label_matches?(el, label) } if label
        selects
      end

      # Find checkable fields (input[type=checkbox|radio]) matching the
      # given criteria.
      def find_checkable_fields(scope, name: nil, checked: nil)
        fields = scope.query_selector_all("input[type='checkbox'], input[type='radio']").to_a
        fields = fields.select { |el| attribute_matches?(el, "name", name) } if name
        fields = fields.select { |el| el.get_attribute("checked") } if checked == true
        fields = fields.reject { |el| el.get_attribute("checked") } if checked == false
        fields
      end

      def attribute_matches?(element, attr_name, expected)
        actual = element.get_attribute(attr_name).to_s
        case expected
        when Regexp
          actual.match?(expected)
        else
          if expected.respond_to?(:matches?)
            expected.matches?(actual)
          else
            actual == expected.to_s
          end
        end
      end

      # A field's label is either a <label for=...> pointing at its id,
      # or the nearest <label> ancestor wrapping it.
      def field_label_matches?(field, expected_label)
        id = field.get_attribute("id")
        if id && !id.empty?
          label = field.owner_document.query_selector("label[for='#{id}']")
          return true if label && DomMatching.text_matches?(label.text_content, expected_label)
        end

        parent = field.parent_node
        while parent
          if parent.respond_to?(:tag_name) && parent.tag_name == "LABEL"
            return DomMatching.text_matches?(parent.text_content, expected_label)
          end
          parent = parent.respond_to?(:parent_node) ? parent.parent_node : nil
        end

        false
      end

      def form_method_matches?(form, expected_method)
        actual_method = form.get_attribute("method").to_s.downcase
        if actual_method == "post"
          hidden_method = form.query_selector("input[type='hidden'][name='_method']")
          actual_method = hidden_method.get_attribute("value").to_s.downcase if hidden_method
        end
        actual_method == expected_method.to_s.downcase
      end
    end
  end
end
