# frozen_string_literal: true

require_relative "selector_ast"
require_relative "element_state"
require_relative "backend_prefilter"
require_relative "infra"

module Dommy
  module Internal
    module SelectorMatcher
      module_function

      # `verified:` — see Match#list?.
      def matches?(element, selector_ast, scope: nil, verified: nil)
        return false unless element&.respond_to?(:__dommy_backend_node__)

        Match.for(element.owner_document, scope).list?(element, selector_ast, verified: verified)
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

        match = Match.for(BackendPrefilter.document_of(root), scope)
        element_descendants(root).select do |element|
          match.list?(element, selector_ast)
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

        match = Match.for(BackendPrefilter.document_of(root), scope)
        catch(:found) do
          each_descendant(root) do |element|
            throw(:found, element) if match.list?(element, selector_ast)
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
        doc = BackendPrefilter.document_of(root)
        return nil unless doc

        match = Match.for(doc, scope)
        prefilters = BackendPrefilter.static_prefilters(selector_ast, quirks: match.quirks)
        return nil unless prefilters

        backend_root = BackendPrefilter.backend_root_of(root)
        return nil unless backend_root

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
                next unless element && match.list?(element, selector_ast, verified: verified)

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
            next unless element && match.list?(element, selector_ast, verified: single)

            out << element
            throw(:done) if first
          end
        end
        out
      end

      def closest(element, selector_ast)
        # DOM Standard: closest keeps the *original* element as the scoping
        # root for every iteration.
        match = Match.for(element.owner_document, element)
        node = element
        while node&.respond_to?(:matches?)
          return node if match.list?(node, selector_ast)

          node = node.parent_element
        end
        nil
      end

      ELEMENT_NODE = 1

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

      # Selectors 4 §6.4: the selector names a local name and a namespace
      # condition, and it matches when ANY attribute meeting both passes the
      # value test. `[*|att=v]` therefore looks at every `att`, in every
      # namespace — not just the first one found, and not just the one in no
      # namespace.
      def matches_attribute?(element, selector)
        attribute_values(element, selector).any? { |actual| attribute_value_matches?(actual, selector) }
      end

      # §6.3 / §6.3.3: the value is compared ASCII case-insensitively under the
      # `i` flag (KELVIN SIGN is not `k`), and `~=` splits on ASCII whitespace
      # (TAB, LF, FF, CR, SPACE — not VT).
      def attribute_value_matches?(actual, selector)
        return true unless selector.matcher

        actual = actual.to_s
        expected = selector.value.to_s
        if selector.case_flag.to_s.downcase == "i"
          actual = actual.downcase(:ascii)
          expected = expected.downcase(:ascii)
        end
        case selector.matcher
        when "=" then actual == expected
        when "~=" then actual.split(Infra::ASCII_WHITESPACE).include?(expected)
        when "|=" then actual == expected || actual.start_with?("#{expected}-")
        # `^=`/`$=`/`*=` against the empty string never match (Selectors 4 §6.2).
        when "^=" then !expected.empty? && actual.start_with?(expected)
        when "$=" then !expected.empty? && actual.end_with?(expected)
        when "*=" then !expected.empty? && actual.include?(expected)
        else false
        end
      end

      # The values of the attributes the selector's name and namespace accept.
      # An unprefixed (or `|`-prefixed) selector accepts only attributes in no
      # namespace, `*|` accepts any, and a declared prefix that namespace. The
      # name is the LOCAL name, matched with the element's attribute-name case
      # rule — not the qualified name a by-name lookup (`getAttribute`) uses,
      # which would take `x:att` or a namespaced `att` for `att`.
      def attribute_values(element, selector)
        local_name = element.__internal_normalize_attr_key__(selector.name.to_s)
        # :none (`|att`) and nil (no prefix) both mean no namespace.
        namespace = selector.namespace == :none ? nil : selector.namespace
        return no_namespace_attribute_values(element, local_name) if namespace.nil?

        attribute_values_in(element, local_name, namespace)
      end

      # The common shape, `[att]` / `[att=v]`, on the hot path of every cascade:
      # at most one attribute, read natively (Backend.no_namespace_attribute_value).
      def no_namespace_attribute_values(element, local_name)
        value = Backend.no_namespace_attribute_value(element.__dommy_backend_node__, local_name)
        value.nil? ? [] : [value]
      end

      def attribute_values_in(element, local_name, namespace)
        Backend.attribute_nodes(element.__dommy_backend_node__).filter_map do |attr|
          info = Backend.attribute_ns_info(attr)
          next unless info[:local_name] == local_name
          next unless namespace == :any || info[:namespace_uri] == namespace

          info[:value]
        end
      end

      # The pseudo-classes whose answer depends on nothing but the element
      # (Match answers the rest).
      def matches_pseudo_class?(element, pseudo)
        case pseudo.name
        when "root" then element.owner_document&.document_element.equal?(element)
        when "empty" then element.child_nodes.none? { |node| element_node?(node) || text_node_content?(node) }
        when "first-child" then element.previous_element_sibling.nil?
        when "last-child" then element.next_element_sibling.nil?
        when "only-child" then element.previous_element_sibling.nil? && element.next_element_sibling.nil?
        when "first-of-type" then previous_of_type(element).nil?
        when "last-of-type" then next_of_type(element).nil?
        when "only-of-type" then previous_of_type(element).nil? && next_of_type(element).nil?
        when "nth-of-type" then nth_of_type?(element, pseudo.argument, false)
        when "nth-last-of-type" then nth_of_type?(element, pseudo.argument, true)
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

require_relative "selector_match"
require_relative "complex_match"
