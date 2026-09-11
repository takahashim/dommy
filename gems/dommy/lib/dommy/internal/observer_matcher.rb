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

      # WHATWG "queue a mutation record" step 2: the target's inclusive
      # ancestors, nearest first. Steps 3-4 walk this list in order, and the
      # observers are appended to the pending set in that order — which is the
      # order their callbacks run at the microtask checkpoint.
      def inclusive_ancestors(target_wrapped)
        chain = []
        node = target_wrapped
        # A malformed tree must not hang the walk.
        4096.times do
          break if node.nil?

          chain << node
          node = node.respond_to?(:parent_node) ? node.parent_node : nil
        end
        chain
      end

      # Wrappers for the same node are not always the same Ruby object.
      def same_node?(a, b)
        return false if a.nil? || b.nil?

        a.equal?(b) || a == b
      end
    end
  end
end
