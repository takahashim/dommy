# frozen_string_literal: true

require_relative "selector_ast"
require_relative "element_state"
require_relative "backend_prefilter"

module Dommy
  module Internal
    module SelectorMatcher
      HTML_NS = "http://www.w3.org/1999/xhtml"
      SVG_NS = "http://www.w3.org/2000/svg"

      module_function

      # `verified:` — see #matches_complex?; only passed by fast_query's
      # single-selector paths, where the one prefilter belongs to the one
      # complex selector in the list.
      def matches?(element, selector_ast, scope: nil, verified: nil)
        return false unless element&.respond_to?(:__dommy_backend_node__)

        selector_ast.selectors.any? { |complex| matches_complex?(element, complex, scope: scope, verified: verified) }
      end

      # querySelectorAll. The candidate set is exactly `root`'s descendants:
      # querySelector(All) results are always descendants of the context node, so
      # we walk only its subtree. (An element scope used to walk up to the document
      # and back down, filtering every element by `root.contains?` — O(whole tree)
      # instead of O(subtree).) `scope` is still threaded into #matches? so a
      # `:scope`-relative selector resolves against the context; the matcher climbs
      # to ancestors above `root` itself when a left-hand combinator needs them.
      def query(root, selector_ast, scope: nil)
        scope ||= default_scope(root)
        fast = fast_query(root, selector_ast, scope: scope)
        return fast if fast

        element_descendants(root).select do |element|
          matches?(element, selector_ast, scope: scope)
        end
      end

      # querySelector — the first element in document order that matches, or nil.
      # Same candidate set and scoping as #query, but it stops at the first match
      # rather than collecting every match and taking .first. A querySelector-heavy
      # SPA spends much of its time here, and most queries either match early or
      # are single-purpose, so short-circuiting the walk avoids touching (and
      # matching against) the rest of the tree.
      def query_first(root, selector_ast, scope: nil)
        scope ||= default_scope(root)
        fast = fast_query(root, selector_ast, scope: scope, first: true)
        return fast.first if fast

        catch(:found) do
          each_descendant(root) do |element|
            throw(:found, element) if matches?(element, selector_ast, scope: scope)
          end
          nil
        end
      end

      # Backend pre-filter fast path. The Ruby matcher wraps EVERY descendant into
      # a Dommy element before matching — so a `.foo` query over a 5000-element
      # tree wraps all 5000 to return the 50 matches. Instead, walk the backend
      # (lexbor) nodes directly and gate each by a cheap static pre-filter taken
      # from the subject (rightmost) compound — its id, class, or a required
      # attribute, read straight off the backend node — and only wrap + run the
      # full #matches? on the candidates that pass. The pre-filter is a SUPERSET of
      # the subject's requirement (no false negatives), so #matches? (the authority,
      # which still handles combinators, pseudo-classes and types) yields exactly
      # the same set, in the same document order. Returns the matches (possibly
      # empty), or nil when the selector has no static subject pre-filter (a
      # universal/pseudo-only subject) — then the caller uses the Ruby matcher.
      def fast_query(root, selector_ast, scope:, first: false)
        prefilters = BackendPrefilter.static_prefilters(selector_ast)
        return nil unless prefilters

        backend_root = BackendPrefilter.backend_root_of(root)
        doc = BackendPrefilter.document_of(root)
        return nil unless backend_root && doc

        # The overwhelmingly common case is one selector (one pre-filter); skip the
        # Array#any? block dispatch on every node for it.
        single = prefilters.size == 1 ? prefilters.first : nil

        # Index fast path: a single id/class/tag pre-filter looks its candidates up
        # directly (O(matches)) instead of walking the whole (sub)tree per call —
        # the dominant cost on a jQuery-heavy page (`$.find` → querySelectorAll).
        # Works for an element scope too (jQuery `.find` is element-scoped): the
        # index restricts candidates to the scope's pre-order interval. Falls
        # through to the walk for an :attr pre-filter / multi-selector list / a
        # scope the index doesn't know (candidates == nil).
        if single && (index = doc.__internal_selector_index__)
          scope_node = root.equal?(doc) ? nil : backend_root
          candidates = index.candidates(single, scope_node)
          if candidates
            # An id/class index hit is an exact test of the prefilter (the
            # index buckets by id value / class token), so the subject can
            # skip that attribute re-read; :type stays unverified (superset).
            verified = %i[id class].include?(single[0]) ? single : nil
            out = []
            catch(:done) do
              candidates.each do |bnode|
                element = doc.wrap_node(bnode)
                next unless element && matches?(element, selector_ast, scope: scope, verified: verified)

                out << element
                throw(:done) if first
              end
            end
            return out
          end
        end

        out = []
        catch(:done) do
          BackendPrefilter.each_backend_descendant(backend_root) do |bnode|
            hit = single ? BackendPrefilter.backend_passes?(bnode, single) : prefilters.any? { |pf| BackendPrefilter.backend_passes?(bnode, pf) }
            next unless hit

            element = doc.wrap_node(bnode)
            # `single` was just tested on this very backend node, so the
            # subject compound skips its re-read (multi-selector lists don't
            # know WHICH prefilter passed — they stay unverified).
            next unless element && matches?(element, selector_ast, scope: scope, verified: single)

            out << element
            throw(:done) if first
          end
        end
        out
      end

      def closest(element, selector_ast)
        node = element
        while node&.respond_to?(:matches?)
          # DOM Standard: closest keeps the *original* element as the
          # scoping root for every iteration.
          return node if matches?(node, selector_ast, scope: element)

          node = node.parent_element
        end
        nil
      end

      # Match a complex selector with the rightmost compound as subject,
      # evaluating right-to-left WITH backtracking: descendant and `~`
      # combinators have multiple candidates, and a failure further left
      # must retry the next candidate (`.a > .b .c` where the nearest
      # `.b` ancestor has the wrong parent).
      #
      # `anchor:`/`leading:` carry :has() semantics — when the chain is
      # fully consumed, its leftmost element must additionally relate to
      # the anchor via the relative selector's leading combinator.
      #
      # `verified:` is a prefilter tuple the caller has ALREADY tested against
      # the element's backend node (fast_query's gate); the subject compound
      # skips re-reading that one simple selector's attribute.
      def matches_complex?(element, complex, scope:, anchor: nil, leading: nil, verified: nil)
        parts = complex.parts
        return false unless matches_compound?(element, parts.last.compound, scope: scope, verified: verified)

        match_left_from(element, parts, parts.length - 1, scope: scope, anchor: anchor, leading: leading)
      end

      # Match parts[0...index] to the left of `current` (already matched
      # against parts[index]). Recursion gives the backtracking: each
      # candidate that satisfies the next compound also has to complete
      # the rest of the chain, otherwise the search continues.
      def match_left_from(current, parts, index, scope:, anchor:, leading:)
        if index.zero?
          return true if anchor.nil?

          return anchor_relation?(current, anchor, leading || :descendant)
        end

        combinator = parts[index].combinator || :descendant
        compound = parts[index - 1].compound
        case combinator
        when :child
          parent = current.parent_element
          !parent.nil? && matches_compound?(parent, compound, scope: scope) &&
            match_left_from(parent, parts, index - 1, scope: scope, anchor: anchor, leading: leading)
        when :next_sibling
          sib = current.previous_element_sibling
          !sib.nil? && matches_compound?(sib, compound, scope: scope) &&
            match_left_from(sib, parts, index - 1, scope: scope, anchor: anchor, leading: leading)
        when :subsequent_sibling
          sib = current.previous_element_sibling
          while sib
            if matches_compound?(sib, compound, scope: scope) &&
               match_left_from(sib, parts, index - 1, scope: scope, anchor: anchor, leading: leading)
              return true
            end

            sib = sib.previous_element_sibling
          end
          false
        when :column
          # `||` needs table column semantics Dommy doesn't model; the
          # design memo keeps it unsupported — match nothing (never treat
          # it as a descendant combinator).
          false
        else # :descendant
          match_descendant_left(current, compound, parts, index, scope: scope, anchor: anchor, leading: leading)
        end
      end

      # The descendant combinator walks EVERY ancestor of `current`. Wrapping each
      # one into a Dommy element (to run #matches_compound?) was the dominant cost
      # on a jQuery-heavy page. So gate each ancestor by the left compound's static
      # prefilter on the BACKEND node first — a superset, so #matches_compound? is
      # still authoritative — and only wrap the ancestors that can possibly match.
      # Prefilters the index can answer an ancestor existence query for.
      INDEXABLE_ANCESTOR_KINDS = %i[id class type].freeze

      def match_descendant_left(current, compound, parts, index, scope:, anchor:, leading:)
        doc = current.owner_document
        prefilter = BackendPrefilter.prefilter_for(compound) # nil ⇒ no static gate, must wrap every ancestor

        # Ask the index about `current`'s ancestors before walking them. For an
        # indexable compound this is O(log):
        #   - no ancestor even passes the (necessary) prefilter ⇒ the whole branch
        #     fails, skip the walk entirely (the big win: candidates with no such
        #     ancestor used to walk to the root for nothing);
        #   - additionally, when this is the chain's LEFTMOST compound (index == 1,
        #     no :has anchor) and it is EXACTLY a class/id (so the index match is
        #     not just a superset), any matching ancestor completes the chain.
        if doc && prefilter && INDEXABLE_ANCESTOR_KINDS.include?(prefilter[0]) &&
           (sel_index = doc.__internal_selector_index__) &&
           (enter = sel_index.enter_of(current.__dommy_backend_node__))
          return false unless sel_index.any_ancestor?(prefilter, enter)
          return true if index == 1 && anchor.nil? && BackendPrefilter.exact_class_or_id_prefilter(compound)
        end

        backend = current.__dommy_backend_node__
        backend = backend && backend.parent
        while backend && doc
          if backend.node_type == ELEMENT_NODE && (prefilter.nil? || BackendPrefilter.backend_passes?(backend, prefilter))
            parent = doc.wrap_node(backend)
            # The prefilter was just tested on this ancestor's backend node.
            if parent && matches_compound?(parent, compound, scope: scope, verified: prefilter) &&
               match_left_from(parent, parts, index - 1, scope: scope, anchor: anchor, leading: leading)
              return true
            end
          end
          backend = backend.parent
        end
        false
      end

      ELEMENT_NODE = 1

      # Does `leftmost` stand in `combinator` relation to the :has()
      # anchor? (The implied :scope at the head of a relative selector.)
      def anchor_relation?(leftmost, anchor, combinator)
        case combinator
        when :child
          anchor.equal?(leftmost.parent_element)
        when :next_sibling
          anchor.equal?(leftmost.previous_element_sibling)
        when :subsequent_sibling
          sib = leftmost.previous_element_sibling
          while sib
            return true if anchor.equal?(sib)

            sib = sib.previous_element_sibling
          end
          false
        else # :descendant
          !anchor.equal?(leftmost) && anchor.respond_to?(:contains?) && anchor.contains?(leftmost)
        end
      end

      # `verified:` (a prefilter tuple already tested on the backend node)
      # lets the one simple selector it proves skip its attribute re-read —
      # the prefilter's id/class/attr-presence checks are exact, not just
      # supersets, for that selector (a :type prefilter is a superset, so it
      # is never passed as verified).
      def matches_compound?(element, compound, scope:, verified: nil)
        # A pseudo-element subject never matches an element (querySelector*,
        # matches). The cascade strips pseudo-elements before matching and
        # indexes those rules separately.
        return false if compound.pseudo_element
        return false unless matches_type?(element, compound.type)

        compound.subclass_selectors.all? do |selector|
          prefilter_proves?(selector, verified) || matches_simple?(element, selector, scope: scope)
        end
      end

      # Whether the already-tested prefilter tuple proves this simple selector
      # true, making its own backend read redundant. Only exact-equivalence
      # cases qualify: same-value id/class (class_attr_token? splits on the
      # same ASCII whitespace as class_tokens). Attribute presence does NOT —
      # the backend lookup behind the prefilter answers `[a]` with a namespaced
      # `xml:a`, and Selectors §6.2 has an unprefixed attribute selector match
      # only attributes in no namespace, so matches_attribute? has to read it.
      def prefilter_proves?(selector, verified)
        return false unless verified

        kind, value = verified
        case kind
        when :id then selector.is_a?(SelectorAST::IdSelector) && selector.value == value
        when :class then selector.is_a?(SelectorAST::ClassSelector) && selector.value == value
        else false
        end
      end

      def matches_type?(element, type)
        return true unless type
        return matches_type_namespace?(element, type.namespace) if type.is_a?(SelectorAST::UniversalSelector)

        return false unless matches_type_namespace?(element, type.namespace)

        actual = element.local_name.to_s
        # Selectors §6.1 compares a type selector to the local name exactly; HTML
        # relaxes that for HTML elements in an HTML document by ASCII-lowercasing
        # THE SELECTOR — not the element. So `DIV` and `Div` both find the `div`
        # the parser made, while the `DIV` only createElementNS can make is
        # unreachable by any spelling (the note in §6.1 says so outright), and an
        # SVG `rect` keeps its own case.
        return actual == type.name.to_s if type.already_ascii_lowercase?
        return actual == type.ascii_lowercased_name if ElementState.html_element?(element) && ElementState.html_document?(element)

        actual == type.name.to_s
      end

      # Namespace values the parser produces: nil (no prefix and no default
      # namespace — matches any namespace), :any (`*|`), :none (`|` — only the
      # null namespace), or a URI String (a resolved `prefix|` or the default
      # namespace from @namespace) — the element must be in that namespace.
      def matches_type_namespace?(element, namespace)
        return true if namespace.nil? || namespace == :any
        return element.namespace_uri.to_s.empty? if namespace == :none

        element.namespace_uri.to_s == namespace.to_s
      end

      def matches_simple?(element, selector, scope:)
        case selector
        when SelectorAST::IdSelector
          element.get_attribute("id").to_s == selector.value
        when SelectorAST::ClassSelector
          element.class_list.include?(selector.value)
        when SelectorAST::AttributeSelector
          matches_attribute?(element, selector)
        when SelectorAST::PseudoClass
          matches_pseudo_class?(element, selector, scope: scope)
        else
          false
        end
      end

      def matches_attribute?(element, selector)
        actual = attribute_value(element, selector)
        return false if actual.nil?
        return true unless selector.matcher

        actual = actual.to_s
        expected = selector.value.to_s
        if selector.case_flag.to_s.downcase == "i"
          actual = actual.downcase
          expected = expected.downcase
        end
        case selector.matcher
        when "=" then actual == expected
        when "~=" then actual.split(/\s+/).include?(expected)
        when "|=" then actual == expected || actual.start_with?("#{expected}-")
        # `^=`/`$=`/`*=` against the empty string never match (Selectors 4 §6.2).
        when "^=" then !expected.empty? && actual.start_with?(expected)
        when "$=" then !expected.empty? && actual.end_with?(expected)
        when "*=" then !expected.empty? && actual.include?(expected)
        else false
        end
      end

      # Selectors 4 §6.1: an unprefixed (or `|`-prefixed) attribute selector matches
      # only attributes in no namespace, `*|` matches one in any namespace by its
      # local name, and a declared prefix matches that namespace. querySelector
      # declares no prefixes, so only the first two shapes reach here from the DOM.
      def attribute_value(element, selector)
        name = selector.name.to_s
        case selector.namespace
        when :any then any_namespace_attribute_value(element, name)
        when nil, :none then element.get_attribute(name)
        else element.get_attribute_ns(selector.namespace, name)
        end
      end

      # `[*|att]` — the no-namespace read covers the common case; a namespaced
      # attribute is found by scanning for the local name, since the qualified
      # name it is stored under (`xlink:href`) is not what the selector spells.
      def any_namespace_attribute_value(element, local_name)
        value = element.get_attribute(local_name)
        return value unless value.nil?

        Backend.attribute_nodes(element.__dommy_backend_node__).each do |attr|
          info = Backend.attribute_ns_info(attr)
          return info[:value] if info[:local_name] == local_name
        end
        nil
      end

      def matches_pseudo_class?(element, pseudo, scope:)
        case pseudo.name
        when "scope" then scope ? element.equal?(scope) : false
        when "root" then element.owner_document&.document_element.equal?(element)
        when "empty" then element.child_nodes.none? { |node| element_node?(node) || text_node_content?(node) }
        when "first-child" then element.previous_element_sibling.nil?
        when "last-child" then element.next_element_sibling.nil?
        when "only-child" then element.previous_element_sibling.nil? && element.next_element_sibling.nil?
        when "first-of-type" then previous_of_type(element).nil?
        when "last-of-type" then next_of_type(element).nil?
        when "only-of-type" then previous_of_type(element).nil? && next_of_type(element).nil?
        when "nth-child" then nth_child?(element, pseudo.argument, false, scope: scope)
        when "nth-last-child" then nth_child?(element, pseudo.argument, true, scope: scope)
        when "nth-of-type" then nth_of_type?(element, pseudo.argument, false)
        when "nth-last-of-type" then nth_of_type?(element, pseudo.argument, true)
        when "is", "where" then matches?(element, pseudo.argument, scope: scope)
        when "not" then !matches?(element, pseudo.argument, scope: scope)
        when "has" then has_relative?(element, pseudo.argument, scope: scope)
        when "checked" then Internal.checked_state?(element)
        when "enabled" then ElementState.enableable_element?(element) && !ElementState.disabled_element?(element)
        when "disabled" then ElementState.enableable_element?(element) && ElementState.disabled_element?(element)
        when "focus", "focus-visible" then element.owner_document&.__internal_focused_element__.equal?(element)
        when "focus-within"
          focused = element.owner_document&.__internal_focused_element__
          focused && (element.equal?(focused) || element.contains?(focused))
        when "hover"
          hovered = element.owner_document&.__internal_hovered_element__
          hovered && (element.equal?(hovered) || element.contains?(hovered))
        when "invalid" then ElementState.constraint_invalid?(element)
        when "valid" then ElementState.constraint_valid?(element)
        when "required" then ElementState.form_control_required?(element)
        when "optional" then ElementState.form_control_optional?(element)
        when "read-only" then ElementState.read_only_element?(element)
        when "read-write" then ElementState.read_write_element?(element)
        when "active", "visited" then false # supported-but-currently-false (no pointer state / history)
        when "dir" then ElementState.dir_match?(element, pseudo.argument)
        when "target" then target_element?(element)
        when "lang" then ElementState.lang_match?(element, pseudo.argument)
        when "link" then ElementState.link_element?(element)
        when "any-link" then ElementState.link_element?(element)
        else
          false
        end
      end

      # `:has(RS)` — the relative selector is anchored at `element` (the
      # implied :scope). Candidates are potential *subjects* (the relative
      # complex's rightmost compound); the anchor relation of the chain's
      # leftmost element is enforced inside matches_complex? via anchor:/
      # leading:, so e.g. `section:has(.a .b)` cannot satisfy `.a` with an
      # ancestor outside the section, and `:has(+ .a .b)` finds subjects
      # inside the adjacent sibling. Inside :has, `:scope` is the anchor.
      # `:has(RS)` anchors the relative selector at `element`, but `:scope` keeps
      # meaning the scoping root of the enclosing query — so `el.closest(":has(> :scope)")`
      # asks for an ancestor whose child is `el`, not one whose child is itself.
      def has_relative?(element, relative_selectors, scope:)
        relative_selectors.any? do |relative|
          leading = relative.leading_combinator || :descendant
          relative_candidates(element, leading).any? do |candidate|
            matches_complex?(candidate, relative.complex, scope: scope, anchor: element, leading: leading)
          end
        end
      end

      # The subject search space per leading combinator: descendants for
      # descendant/child relations; the following sibling(s) *and their
      # descendants* for sibling relations (`:has(+ .a .b)`'s subject lives
      # inside the next sibling).
      def relative_candidates(element, combinator)
        case combinator
        when :next_sibling
          sib = element.next_element_sibling
          sib ? [sib] + element_descendants(sib) : []
        when :subsequent_sibling
          out = []
          sib = element.next_element_sibling
          while sib
            out << sib
            out.concat(element_descendants(sib))
            sib = sib.next_element_sibling
          end
          out
        else # :descendant / :child
          element_descendants(element)
        end
      end

      def nth_child?(element, nth, reverse, scope:)
        siblings = element_siblings(element)
        siblings = siblings.reverse if reverse
        if nth.of_selector_list
          siblings = siblings.select { |candidate| matches?(candidate, nth.of_selector_list, scope: scope) }
        end
        index = siblings.index(element)
        index && nth_match?(index + 1, nth.a, nth.b)
      end

      def nth_of_type?(element, nth, reverse)
        siblings = element_siblings(element).select { |candidate| same_type?(candidate, element) }
        siblings = siblings.reverse if reverse
        index = siblings.index(element)
        index && nth_match?(index + 1, nth.a, nth.b)
      end

      def nth_match?(index, a, b)
        return index == b if a.zero?

        n = index - b
        (n % a).zero? && (n / a) >= 0
      end

      def element_siblings(element)
        parent = element.parent_element
        parent ? parent.children.to_a : [element]
      end

      def previous_of_type(element)
        sib = element.previous_element_sibling
        while sib
          return sib if same_type?(sib, element)

          sib = sib.previous_element_sibling
        end
        nil
      end

      def next_of_type(element)
        sib = element.next_element_sibling
        while sib
          return sib if same_type?(sib, element)

          sib = sib.next_element_sibling
        end
        nil
      end

      def same_type?(a, b)
        a.namespace_uri == b.namespace_uri && a.local_name == b.local_name
      end

      # The scoping root of a query. A Document is not an element, so `:scope`
      # falls back to its document element there (`document.querySelector(":scope")`
      # is the root element); a DocumentFragment or ShadowRoot has no such
      # fallback, and `:scope` simply matches nothing inside one.
      def default_scope(root)
        return root.document_element if root.is_a?(Document)

        root if root.respond_to?(:__dommy_backend_node__)
      end

      # `:target` — the element the document's URL fragment points at. It has to
      # be in the document: an id match inside a detached subtree or a fragment
      # is not the target of anything.
      def target_element?(element)
        target = Internal.target_id(element.owner_document)
        return false if target.nil?

        element.get_attribute("id").to_s == target.to_s && element.is_connected?
      end

      def element_descendants(root)
        out = []
        each_descendant(root) { |element| out << element }
        out
      end

      # Yield every descendant element of `root` in document (pre-order) order,
      # without materializing the full list — so a first-match walk (#query_first)
      # can stop early. #element_descendants collects them when the whole set is
      # needed (#query / querySelectorAll).
      def each_descendant(root, &block)
        child_elements(root).each do |child|
          block.call(child)
          each_descendant(child, &block)
        end
      end

      def child_elements(root)
        if root.is_a?(Document)
          root.children.to_a
        elsif root.respond_to?(:children)
          root.children.to_a
        else
          []
        end
      end

      def element_node?(node)
        node.respond_to?(:tag_name)
      end

      # Text that keeps an element from being `:empty`. Any non-empty text does,
      # white space included: Selectors 4's wording allows "document white
      # space", but WPT (dom/nodes/selectors.js, which asserts `<p> </p>` is not
      # `:empty`) and every engine read it as Selectors 3 did.
      def text_node_content?(node)
        node.respond_to?(:node_type) && node.node_type == 3 && !node.text_content.to_s.empty?
      end
    end
  end
end
