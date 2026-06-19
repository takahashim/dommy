# frozen_string_literal: true

require_relative "selector_ast"

module Dommy
  module Internal
    module SelectorMatcher
      HTML_NS = "http://www.w3.org/1999/xhtml"
      SVG_NS = "http://www.w3.org/2000/svg"

      module_function

      def matches?(element, selector_ast, scope: nil)
        return false unless element&.respond_to?(:__dommy_backend_node__)

        selector_ast.selectors.any? { |complex| matches_complex?(element, complex, scope: scope) }
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
        prefilters = static_prefilters(selector_ast)
        return nil unless prefilters

        backend_root = backend_root_of(root)
        doc = document_of(root)
        return nil unless backend_root && doc

        out = []
        catch(:done) do
          each_backend_descendant(backend_root) do |bnode|
            next unless prefilters.any? { |pf| backend_passes?(bnode, pf) }

            element = doc.wrap_node(bnode)
            next unless element && matches?(element, selector_ast, scope: scope)

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
      def matches_complex?(element, complex, scope:, anchor: nil, leading: nil)
        parts = complex.parts
        return false unless matches_compound?(element, parts.last.compound, scope: scope)

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
          parent = current.parent_element
          while parent
            if matches_compound?(parent, compound, scope: scope) &&
               match_left_from(parent, parts, index - 1, scope: scope, anchor: anchor, leading: leading)
              return true
            end

            parent = parent.parent_element
          end
          false
        end
      end

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

      def matches_compound?(element, compound, scope:)
        # A pseudo-element subject never matches an element (querySelector*,
        # matches). The cascade strips pseudo-elements before matching and
        # indexes those rules separately.
        return false if compound.pseudo_element
        return false unless matches_type?(element, compound.type)

        compound.subclass_selectors.all? { |selector| matches_simple?(element, selector, scope: scope) }
      end

      def matches_type?(element, type)
        return true unless type
        return matches_type_namespace?(element, type.namespace) if type.is_a?(SelectorAST::UniversalSelector)

        return false unless matches_type_namespace?(element, type.namespace)

        actual = element.local_name.to_s
        expected = type.name.to_s
        if html_document?(element)
          actual.downcase == expected.downcase
        else
          actual == expected
        end
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
        name = selector.name.to_s
        actual = element.get_attribute(name)
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
        when "enabled" then enableable_element?(element) && !disabled_element?(element)
        when "disabled" then enableable_element?(element) && disabled_element?(element)
        when "focus", "focus-visible" then element.owner_document&.__internal_focused_element__.equal?(element)
        when "focus-within"
          focused = element.owner_document&.__internal_focused_element__
          focused && (element.equal?(focused) || element.contains?(focused))
        when "hover"
          hovered = element.owner_document&.__internal_hovered_element__
          hovered && (element.equal?(hovered) || element.contains?(hovered))
        when "active", "visited" then false # supported-but-currently-false (no pointer state / history)
        when "dir" then dir_match?(element, pseudo.argument)
        when "target" then element.get_attribute("id").to_s == Internal.target_id(element.owner_document).to_s && !Internal.target_id(element.owner_document).nil?
        when "lang" then lang_match?(element, pseudo.argument)
        when "link" then link_element?(element)
        when "any-link" then link_element?(element)
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
      def has_relative?(element, relative_selectors, scope:)
        relative_selectors.any? do |relative|
          leading = relative.leading_combinator || :descendant
          relative_candidates(element, leading).any? do |candidate|
            matches_complex?(candidate, relative.complex, scope: element, anchor: element, leading: leading)
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

      def default_scope(root)
        root if root.respond_to?(:__dommy_backend_node__) && !root.is_a?(Document)
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

      # ----- backend pre-filter fast path (see #fast_query) -----

      # Every descendant ELEMENT of the backend node `bnode`, in document order,
      # excluding `bnode` itself — walking lexbor nodes directly, no Dommy wrap.
      def each_backend_descendant(bnode, &block)
        bnode.element_children.each do |child|
          block.call(child)
          each_backend_descendant(child, &block)
        end
      end

      # One [kind, value] pre-filter per complex selector — taken from its subject
      # (rightmost) compound. nil when ANY subject lacks a static id/class/attribute
      # to filter on (a universal- or pseudo-only subject), so the whole query
      # falls back to the Ruby matcher.
      def static_prefilters(selector_ast)
        selector_ast.selectors.map do |complex|
          compound = complex.parts.last.compound
          return nil if compound.pseudo_element

          prefilter_for(compound) || (return nil)
        end
      end

      # The most selective static check in `compound` (id > class > attribute);
      # nil if it has none. Pseudo-classes/types are NOT used (the type's
      # case/namespace rules and pseudo state are left to the authoritative
      # #matches?), so a tag- or pseudo-only compound returns nil.
      def prefilter_for(compound)
        id = klass = attr = nil
        compound.subclass_selectors.each do |sub|
          case sub
          when SelectorAST::IdSelector then id ||= sub.value
          when SelectorAST::ClassSelector then klass ||= sub.value
          when SelectorAST::AttributeSelector then attr ||= sub.name if sub.namespace.nil?
          end
        end
        return [:id, id] if id
        return [:class, klass] if klass
        return [:attr, attr] if attr

        nil
      end

      # Does the backend node satisfy a pre-filter? A SUPERSET test (presence /
      # exact id / class token) — never a false negative, so #matches? can prune.
      def backend_passes?(bnode, prefilter)
        kind, value = prefilter
        case kind
        when :id then bnode["id"] == value
        when :class then class_attr_token?(bnode["class"], value)
        when :attr then !bnode[value].nil?
        end
      end

      # Is `token` a whitespace-separated word of the raw class attribute? Scans in
      # place (no split/allocation), since this runs for every node in the tree.
      def class_attr_token?(raw, token)
        return false if raw.nil? || raw.empty?

        pos = 0
        len = token.length
        while (i = raw.index(token, pos))
          before = i.zero? || ascii_ws?(raw[i - 1])
          after_index = i + len
          after = after_index >= raw.length || ascii_ws?(raw[after_index])
          return true if before && after

          pos = i + 1
        end
        false
      end

      def ascii_ws?(char)
        char == " " || char == "\t" || char == "\n" || char == "\f" || char == "\r"
      end

      # The backend (lexbor) node whose subtree holds the candidates.
      def backend_root_of(root)
        if root.is_a?(Document)
          root.backend_doc
        elsif root.respond_to?(:__dommy_backend_node__)
          root.__dommy_backend_node__
        end
      end

      # The owning Document (for identity-stable #wrap_node of a backend match).
      def document_of(root)
        return root if root.is_a?(Document)

        root.document if root.respond_to?(:document)
      end

      def element_node?(node)
        node.respond_to?(:tag_name)
      end

      def text_node_content?(node)
        node.respond_to?(:node_type) && node.node_type == 3 && !node.text_content.to_s.empty?
      end

      def html_element?(element)
        element.namespace_uri.nil? || element.namespace_uri == HTML_NS
      end

      def html_document?(element)
        element.owner_document&.content_type.to_s.downcase.include?("html")
      end

      def enableable_element?(element)
        %w[button input select textarea optgroup option fieldset].include?(element.local_name.to_s.downcase)
      end

      def disabled_element?(element)
        return true if element.has_attribute?("disabled")

        if element.local_name.to_s.downcase == "option"
          parent = element.parent_element
          return true if parent&.local_name.to_s.downcase == "optgroup" && parent.has_attribute?("disabled")
        end
        fieldset_disabled?(element)
      end

      def fieldset_disabled?(element)
        parent = element.parent_element
        while parent
          if parent.local_name.to_s.downcase == "fieldset" && parent.has_attribute?("disabled")
            legend = first_legend_child(parent)
            return false if legend && contains_element?(legend, element)

            return true
          end

          parent = parent.parent_element
        end
        false
      end

      def first_legend_child(fieldset)
        fieldset.children.to_a.find { |child| child.local_name.to_s.downcase == "legend" }
      end

      def contains_element?(ancestor, element)
        node = element
        while node
          return true if node.equal?(ancestor)

          node = node.parent_element
        end
        false
      end

      # `:lang()` accepts a list of language ranges; the element's content
      # language (nearest lang attribute) must extended-filter-match any of
      # them (RFC 4647 §3.3.2 — so `de-DE` matches `de-Latn-DE`).
      def lang_match?(element, ranges)
        actual = nil
        node = element
        while node
          value = node.get_attribute("lang") if node.respond_to?(:get_attribute)
          if value && !value.to_s.empty?
            actual = value.to_s.downcase
            break
          end
          node = node.parent_element
        end
        return false unless actual

        Array(ranges).any? { |range| lang_range_match?(actual, range.to_s.downcase) }
      end

      def lang_range_match?(actual, range)
        return false if range.empty?
        return true if range == "*"

        tags = actual.split("-")
        subs = range.split("-")
        return false unless subs[0] == "*" || tags[0] == subs[0]

        i = 1
        j = 1
        while j < subs.length
          if subs[j] == "*"
            j += 1
          elsif i >= tags.length
            return false
          elsif tags[i] == subs[j]
            i += 1
            j += 1
          elsif tags[i].length == 1
            # A singleton subtag (e.g. "x") ends the matchable prefix.
            return false
          else
            i += 1
          end
        end
        true
      end

      def link_element?(element)
        %w[a area link].include?(element.local_name.to_s.downcase) && element.has_attribute?("href")
      end

      # `:dir()` from the nearest dir attribute (ltr/rtl; auto and absent
      # fall back to the document default ltr — no computed-direction or
      # content heuristics).
      def dir_match?(element, argument)
        expected = Array(argument).first.to_s.downcase
        return false unless %w[ltr rtl].include?(expected)

        actual = "ltr"
        node = element
        while node
          value = node.get_attribute("dir").to_s.downcase if node.respond_to?(:get_attribute)
          if %w[ltr rtl].include?(value)
            actual = value
            break
          end
          node = node.parent_element
        end
        actual == expected
      end
    end
  end
end
