# frozen_string_literal: true

module Dommy
  module Internal
    module SelectorMatcher
      # One selector match: what it is asked in, the same for every element it
      # visits — the element `:scope` stands for, the document, and whether
      # that document is in quirks mode (HTML has id and class selectors fold
      # ASCII case there) — and the matching that depends on any of it. What
      # depends on none of it stays a SelectorMatcher function.
      class Match
        attr_reader :scope, :document, :quirks

        def self.for(document, scope)
          new(scope, document, document.respond_to?(:quirks_mode?) && document.quirks_mode?)
        end

        def initialize(scope, document, quirks)
          @scope = scope
          @document = document
          @quirks = quirks
        end

        # Whether `element` matches any selector of the list. `verified:` — see
        # #complex?; only fast_query's single-selector paths pass it, where the
        # one prefilter belongs to the one complex selector in the list.
        def list?(element, selector_ast, verified: nil)
          return false unless element&.respond_to?(:__dommy_backend_node__)

          selector_ast.selectors.any? { |complex| complex?(element, complex, verified: verified) }
        end

        # Match a complex selector with the rightmost compound as subject (see
        # ComplexMatch). A single compound with no :has() anchor is the whole
        # match, and needs no more than the compound itself.
        #
        # `anchor:`/`leading:` carry :has() semantics — when the chain is
        # fully consumed, its leftmost element must additionally relate to
        # the anchor via the relative selector's leading combinator.
        #
        # `verified:` is a prefilter tuple the caller has ALREADY tested
        # against the element's backend node (fast_query's gate); the subject
        # compound skips re-reading that one simple selector's attribute.
        def complex?(element, complex, anchor: nil, leading: nil, verified: nil)
          parts = complex.parts
          return false unless compound?(element, parts.last.compound, verified: verified)
          return true if parts.length == 1 && anchor.nil?

          complex_match(complex, anchor, leading).from(element, parts.length - 1)
        end

        # `verified:` (a prefilter tuple already tested on the backend node)
        # lets the one simple selector it proves skip its attribute re-read —
        # the prefilter's id/class/attr-presence checks are exact, not just
        # supersets, for that selector (a :type prefilter is a superset, so it
        # is never passed as verified).
        def compound?(element, compound, verified: nil)
          # A pseudo-element subject never matches an element (querySelector*,
          # matches). The cascade strips pseudo-elements before matching and
          # indexes those rules separately.
          return false if compound.pseudo_element
          return false unless SelectorMatcher.matches_type?(element, compound.type)

          compound.subclass_selectors.all? do |selector|
            SelectorMatcher.prefilter_proves?(selector, verified) || simple?(element, selector)
          end
        end

        private

        # The walk for `complex`. One with no :has() anchor depends on nothing
        # but the selector and this match, so it is made once per selector and
        # reused — the cascade asks every complex selector of a sheet about
        # every element through one Match. An anchored one is :has()'s, made
        # for its anchor.
        def complex_match(complex, anchor, leading)
          return ComplexMatch.new(complex.parts, self, anchor, leading) if anchor

          (@complex_matches ||= {}.compare_by_identity)[complex] ||= ComplexMatch.new(complex.parts, self, nil, nil)
        end

        def simple?(element, selector)
          case selector
          when SelectorAST::IdSelector then id?(element, selector.value)
          when SelectorAST::ClassSelector then class?(element, selector.value)
          when SelectorAST::AttributeSelector then SelectorMatcher.matches_attribute?(element, selector)
          when SelectorAST::PseudoClass then pseudo_class?(element, selector)
          else false
          end
        end

        # HTML: in a quirks-mode document, id and class selectors match ASCII
        # case-insensitively (https://html.spec.whatwg.org/#selectors).
        def id?(element, value)
          id = element.get_attribute("id").to_s
          @quirks ? id.downcase(:ascii) == value.downcase(:ascii) : id == value
        end

        def class?(element, value)
          return element.class_list.include?(value) unless @quirks

          folded = value.downcase(:ascii)
          element.class_list.to_a.any? { |token| token.downcase(:ascii) == folded }
        end

        # The pseudo-classes that depend on the match — `:scope`, the ones
        # holding selectors, `:has()` — and the rest, which SelectorMatcher
        # answers for any match.
        def pseudo_class?(element, pseudo)
          case pseudo.name
          when "scope" then @scope ? element.equal?(@scope) : false
          when "nth-child" then nth_child?(element, pseudo.argument, false)
          when "nth-last-child" then nth_child?(element, pseudo.argument, true)
          when "is", "where" then list?(element, pseudo.argument)
          when "not" then !list?(element, pseudo.argument)
          when "has" then has?(element, pseudo.argument)
          else SelectorMatcher.matches_pseudo_class?(element, pseudo)
          end
        end

        # `:has(RS)` — the relative selector is anchored at `element` (the
        # implied :scope). Candidates are potential *subjects* (the relative
        # complex's rightmost compound); the anchor relation of the chain's
        # leftmost element is enforced inside #complex? via anchor:/leading:,
        # so e.g. `section:has(.a .b)` cannot satisfy `.a` with an ancestor
        # outside the section, and `:has(+ .a .b)` finds subjects inside the
        # adjacent sibling. `:scope` keeps meaning the scoping root of the
        # enclosing query — so `el.closest(":has(> :scope)")` asks for an
        # ancestor whose child is `el`, not one whose child is itself.
        def has?(element, relative_selectors)
          relative_selectors.any? do |relative|
            leading = relative.leading_combinator || :descendant
            SelectorMatcher.relative_candidates(element, leading).any? do |candidate|
              complex?(candidate, relative.complex, anchor: element, leading: leading)
            end
          end
        end

        def nth_child?(element, nth, reverse)
          siblings = SelectorMatcher.element_siblings(element)
          siblings = siblings.reverse if reverse
          siblings = siblings.select { |candidate| list?(candidate, nth.of_selector_list) } if nth.of_selector_list
          index = siblings.index(element)
          index && SelectorMatcher.nth_match?(index + 1, nth.a, nth.b)
        end
      end
    end
  end
end
