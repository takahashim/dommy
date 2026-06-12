# frozen_string_literal: true

require "dommy/internal/element_matching"

module Dommy
  module Rails
    module Lint
      # Inputs whose accessible name comes from elsewhere (value
      # attribute) or that are not user-visible, so a <label> is not
      # expected.
      NON_LABELABLE_INPUT_TYPES = %w[hidden submit button reset image].freeze

      module_function

      def duplicate_ids(document)
        all_elements = document.query_selector_all("*[id]").to_a
        ids = all_elements.map { |el| el.get_attribute("id") }
        ids.select { |id| ids.count(id) > 1 }.uniq
      end

      def invalid_aria_references(document)
        issues = []
        document.query_selector_all("*").each do |el|
          %w[aria-labelledby aria-describedby].each do |attr|
            next unless el.has_attribute?(attr)

            el.get_attribute(attr).to_s.split.each do |id|
              issues << { element: el, attribute: attr, id: id } unless document.get_element_by_id(id)
            end
          end
        end
        issues
      end

      # Lenient policy: aria-label / aria-labelledby / placeholder are
      # all accepted as label substitutes, even though a placeholder is
      # not a sufficient accessible name under WCAG.
      def missing_form_labels(document)
        issues = []
        document.query_selector_all("input, textarea, select").each do |field|
          next if field.tag_name == "INPUT" &&
            NON_LABELABLE_INPUT_TYPES.include?(field.get_attribute("type").to_s.downcase)
          next if field.has_attribute?("aria-label")
          next if field.has_attribute?("aria-labelledby")
          next if field.has_attribute?("placeholder")
          next if Dommy::Internal::ElementMatching.field_labels(field).any?

          issues << { element: field, name: field.get_attribute("name") }
        end
        issues
      end

      def empty_links(document)
        document.query_selector_all("a[href]").to_a.select do |link|
          accessible_link_text(link).empty?
        end
      end

      def nested_interactive_elements(document)
        issues = []
        interactive_elements(document).each do |element|
          parent = element.parent_node
          while parent
            if interactive_element?(parent)
              issues << { element: element, ancestor: parent }
              break
            end
            parent = parent.respond_to?(:parent_node) ? parent.parent_node : nil
          end
        end
        issues
      end

      def interactive_elements(document)
        document.query_selector_all("a[href], button, input, select, textarea, summary").to_a.reject do |element|
          element.tag_name == "INPUT" && element.get_attribute("type").to_s.downcase == "hidden"
        end
      end

      def interactive_element?(element)
        return false unless element.respond_to?(:tag_name)

        case element.tag_name
        when "A"
          element.has_attribute?("href")
        when "BUTTON", "SELECT", "TEXTAREA", "SUMMARY"
          true
        when "INPUT"
          element.get_attribute("type").to_s.downcase != "hidden"
        else
          false
        end
      end

      def accessible_link_text(link)
        [
          link.text_content,
          link.get_attribute("aria-label"),
          link.get_attribute("title"),
          image_alt_text(link)
        ].compact.join.strip
      end

      def image_alt_text(link)
        link.query_selector_all("img").to_a.map { |image| image.get_attribute("alt").to_s }.join
      end
    end
  end
end
