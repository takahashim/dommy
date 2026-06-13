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

      def query(root, selector_ast, scope: nil)
        scope ||= default_scope(root)
        root_for_walk = query_root(root, scope)
        candidates = element_descendants(root_for_walk)
        candidates = candidates.reject { |el| el.equal?(scope) } if scope && !root.is_a?(Document)
        candidates.select do |element|
          next false if scope && !in_scope?(element, scope)

          matches?(element, selector_ast, scope: scope)
        end
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
        when "focus", "focus-visible" then element.owner_document&.__focused_element__.equal?(element)
        when "focus-within"
          focused = element.owner_document&.__focused_element__
          focused && (element.equal?(focused) || element.contains?(focused))
        when "hover"
          hovered = element.owner_document&.__hovered_element__
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

      # DOM Standard scope-match: candidates come from the receiver's
      # *root* (document, fragment, or a detached top element), with the
      # receiver as scoping root — so ancestors outside the receiver still
      # satisfy left-hand compounds. Walking the parent chain (rather than
      # jumping to owner_document) keeps fragment-rooted subtrees queryable.
      def query_root(root, _scope)
        return root if root.is_a?(Document) || root.is_a?(ShadowRoot) || root.is_a?(Fragment)

        node = root
        node = node.parent_node while node.respond_to?(:parent_node) && node.parent_node
        node
      end

      def default_scope(root)
        root if root.respond_to?(:__dommy_backend_node__) && !root.is_a?(Document)
      end

      def in_scope?(element, scope)
        return true if scope.nil? || scope.is_a?(Document)
        return true if scope.equal?(element)
        return scope.contains?(element) if scope.respond_to?(:contains?)

        false
      end

      def element_descendants(root)
        out = []
        child_elements(root).each do |child|
          out << child
          out.concat(element_descendants(child))
        end
        out
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
