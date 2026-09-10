# frozen_string_literal: true

module Dommy
  module Internal
    # Matches a mutation target against an observed node based on observer options.
    # Works exclusively with wrapped DOM nodes (not Nokogiri internals).
    module ObserverMatcher
      module_function

      # Does this observer's target scope match the mutation target?
      # Returns true if:
      #   - target == observed (exact match), OR
      #   - subtree=true AND target is descendant of observed
      def matches?(observed_wrapped, target_wrapped, subtree:)
        return true if target_wrapped.equal?(observed_wrapped)
        return false unless subtree
        return false unless observed_wrapped.respond_to?(:contains?)

        observed_wrapped.contains?(target_wrapped)
      end

      # Special case: Document observation. A plain registration matches the
      # Document node ITSELF, whose child list is the doctype, the document
      # element and any stray comment — `observe(document, {childList: true})`
      # is a legal way to watch those. `subtree` covers the whole tree, but only
      # the tree: WHATWG walks the mutation target's INCLUSIVE ANCESTORS looking
      # for registrations, so a node that is not in this document (a detached
      # one, or one in a fragment) never reaches a registration on it.
      def matches_document?(target_wrapped, subtree:, document: nil)
        return true if target_wrapped.is_a?(Dommy::Document)
        return false unless subtree
        return true if document.nil?

        document.contains?(target_wrapped)
      end
    end
  end
end
