# frozen_string_literal: true

module Dommy
  module Internal
    module SelectorMatcher
      # One complex selector matched right to left from its subject, with
      # backtracking: descendant and `~` combinators have more than one
      # candidate, and a failure further left must retry the next one (`.a >
      # .b .c` where the nearest `.b` ancestor has the wrong parent).
      #
      # The parts, the Match it belongs to and :has()'s anchor and leading
      # combinator stay the same for the whole match — only the element and the
      # position in the parts move — so they are this object's state.
      class ComplexMatch
        # Prefilters the index can answer an ancestor existence query for.
        INDEXABLE_ANCESTOR_KINDS = %i[id class type].freeze

        def initialize(parts, match, anchor, leading)
          @parts = parts
          @match = match
          @anchor = anchor
          @leading = leading
        end

        # Match parts[0...index] to the left of `current` (already matched
        # against parts[index]). Recursion gives the backtracking: each
        # candidate that satisfies the next compound also has to complete the
        # rest of the chain, otherwise the search continues.
        def from(current, index)
          return @anchor.nil? || anchor_relation?(current, @leading || :descendant) if index.zero?

          compound = @parts[index - 1].compound
          case @parts[index].combinator || :descendant
          when :child
            parent = current.parent_element
            !parent.nil? && compound_matches?(parent, compound) && from(parent, index - 1)
          when :next_sibling
            sib = current.previous_element_sibling
            !sib.nil? && compound_matches?(sib, compound) && from(sib, index - 1)
          when :subsequent_sibling
            sib = current.previous_element_sibling
            while sib
              return true if compound_matches?(sib, compound) && from(sib, index - 1)

              sib = sib.previous_element_sibling
            end
            false
          when :column
            # `||` needs table column semantics Dommy doesn't model; the design
            # memo keeps it unsupported — match nothing (never treat it as a
            # descendant combinator).
            false
          else # :descendant
            from_ancestor(current, compound, index)
          end
        end

        private

        def compound_matches?(element, compound, verified: nil)
          @match.compound?(element, compound, verified: verified)
        end

        # The descendant combinator walks EVERY ancestor of `current`. Wrapping
        # each one into a Dommy element (to run #compound_matches?) was the
        # dominant cost on a jQuery-heavy page. So gate each ancestor by the
        # left compound's static prefilter on the BACKEND node first — a
        # superset, so #compound_matches? is still authoritative — and only
        # wrap the ancestors that can possibly match.
        def from_ancestor(current, compound, index)
          doc = @match.document
          prefilter = BackendPrefilter.prefilter_for(compound) # nil ⇒ no static gate, must wrap every ancestor

          # Ask the index about `current`'s ancestors before walking them. For
          # an indexable compound this is O(log):
          #   - no ancestor even passes the (necessary) prefilter ⇒ the whole
          #     branch fails, skip the walk entirely (the big win: candidates
          #     with no such ancestor used to walk to the root for nothing);
          #   - additionally, when this is the chain's LEFTMOST compound
          #     (index == 1, no :has anchor) and it is EXACTLY a class/id (so
          #     the index match is not just a superset), any matching ancestor
          #     completes the chain.
          if doc && prefilter && INDEXABLE_ANCESTOR_KINDS.include?(prefilter[0]) &&
             (sel_index = doc.__internal_selector_index__) &&
             (enter = sel_index.enter_of(current.__dommy_backend_node__))
            return false unless sel_index.any_ancestor?(prefilter, enter)
            return true if index == 1 && @anchor.nil? && BackendPrefilter.exact_class_or_id_prefilter(compound)
          end

          backend = current.__dommy_backend_node__
          backend = backend && backend.parent
          while backend && doc
            if backend.node_type == ELEMENT_NODE &&
               (prefilter.nil? || BackendPrefilter.backend_passes?(backend, prefilter, quirks: @match.quirks))
              parent = doc.wrap_node(backend)
              # The prefilter was just tested on this ancestor's backend node.
              return true if parent && compound_matches?(parent, compound, verified: prefilter) && from(parent, index - 1)
            end
            backend = backend.parent
          end
          false
        end

        # Does `leftmost` stand in `combinator` relation to the :has() anchor?
        # (The implied :scope at the head of a relative selector.)
        def anchor_relation?(leftmost, combinator)
          case combinator
          when :child
            @anchor.equal?(leftmost.parent_element)
          when :next_sibling
            @anchor.equal?(leftmost.previous_element_sibling)
          when :subsequent_sibling
            sib = leftmost.previous_element_sibling
            while sib
              return true if @anchor.equal?(sib)

              sib = sib.previous_element_sibling
            end
            false
          else # :descendant
            !@anchor.equal?(leftmost) && @anchor.respond_to?(:contains?) && @anchor.contains?(leftmost)
          end
        end
      end
    end
  end
end
