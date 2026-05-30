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

    # Adds `:scope` support. Nokogiri compiles `:scope` into a custom XPath
    # function `nokogiri:scope(.)`, calling it as `scope(node_set)`; a scoped
    # query (`el.querySelector(":scope > p")`) resolves it to the context
    # element, so only that element matches. One instance per query — it carries
    # the context node.
    class ScopedCSSPseudoHandlers < CSSPseudoHandlers
      def initialize(scope_node)
        @scope_node = scope_node
      end

      def scope(list)
        list.find_all { |node| node.pointer_id == @scope_node.pointer_id }
      end
    end

    def self.scoped_pseudo_handlers(scope_node)
      ScopedCSSPseudoHandlers.new(scope_node)
    end
  end
end
