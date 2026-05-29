# frozen_string_literal: true

module Dommy
  module Rack
    module_function

    # Simplified visibility check for capybara-style interaction. An element
    # is hidden if it (or an ancestor) is hidden via the `hidden` attribute,
    # an inline `display: none` / `visibility: hidden` style, or is an
    # `<input type="hidden">`. No CSS cascade / computed style / layout.
    def visible?(element)
      return false if element.nil?

      node = element
      while node.respond_to?(:get_attribute)
        return false if hidden_node?(node)

        node = node.respond_to?(:parent_element) ? node.parent_element : nil
        break if node.nil?
      end
      return false if hidden_by_closed_details?(element)

      true
    end

    # Inside a closed <details>, everything except the <summary> is hidden.
    def hidden_by_closed_details?(element)
      return false unless element.respond_to?(:closest)
      return false if element.tag_name == "DETAILS"

      details = element.closest("details")
      return false if details.nil? || details.has_attribute?("open")

      summary = element.closest("summary")
      !(summary && summary.closest("details")&.equal?(details))
    end

    def hidden_node?(element)
      return true if element.has_attribute?("hidden")
      return true if element.tag_name == "TEMPLATE"
      return true if element.tag_name == "INPUT" && element.respond_to?(:type) && element.type == "hidden"

      style = element.get_attribute("style").to_s.downcase
      style.match?(/display\s*:\s*none/) || style.match?(/visibility\s*:\s*hidden/)
    end
  end
end
