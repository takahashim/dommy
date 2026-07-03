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

      # Special case: Document observation. Matches iff subtree=true
      # (a plain target==observed match never applies to a Document).
      def matches_document?(_target_wrapped, subtree:)
        subtree
      end
    end
  end
end
