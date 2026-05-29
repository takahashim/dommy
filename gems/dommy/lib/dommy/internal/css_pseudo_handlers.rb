# frozen_string_literal: true

module Dommy
  module Internal
    # Custom Nokogiri pseudo-class handlers so CSS selectors like
    # `:disabled` / `:enabled` / `:checked` work in query_selector(_all).
    # Nokogiri calls the method named after the pseudo-class with the current
    # node list and expects the filtered list back. Receives raw Nokogiri
    # nodes (not Dommy wrappers).
    class CSSPseudoHandlers < BasicObject
      include ::Kernel

      def disabled(list)
        list.find_all { |node| node.has_attribute?("disabled") }
      end

      def enabled(list)
        list.find_all { |node| !node.has_attribute?("disabled") }
      end

      def checked(list)
        list.find_all { |node| node.has_attribute?("checked") }
      end
    end

    CSS_PSEUDO_HANDLERS = CSSPseudoHandlers.new
  end
end
