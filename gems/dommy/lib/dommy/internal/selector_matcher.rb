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
          return node if matches?(node, selector_ast, scope: node)

          node = node.parent_element
        end
        nil
      end

      def matches_complex?(element, complex, scope:)
        parts = complex.parts
        idx = parts.length - 1
        return false unless matches_compound?(element, parts[idx].compound, scope: scope)

        current = element
        while idx.positive?
          combinator = parts[idx].combinator || :descendant
          idx -= 1
          compound = parts[idx].compound
          current = match_left(current, combinator, compound, scope: scope)
          return false unless current
        end
        true
      end

      def match_left(element, combinator, compound, scope:)
        case combinator
        when :child
          parent = element.parent_element
          parent if parent && matches_compound?(parent, compound, scope: scope)
        when :next_sibling
          sib = element.previous_element_sibling
          sib if sib && matches_compound?(sib, compound, scope: scope)
        when :subsequent_sibling
          sib = element.previous_element_sibling
          while sib
            return sib if matches_compound?(sib, compound, scope: scope)

            sib = sib.previous_element_sibling
          end
          nil
        else
          parent = element.parent_element
          while parent
            return parent if matches_compound?(parent, compound, scope: scope)

            parent = parent.parent_element
          end
          nil
        end
      end

      def matches_compound?(element, compound, scope:)
        return false unless matches_type?(element, compound.type)

        compound.subclass_selectors.all? { |selector| matches_simple?(element, selector, scope: scope) }
      end

      def matches_type?(element, type)
        return true unless type
        return true if type.is_a?(SelectorAST::UniversalSelector)

        actual = element.local_name.to_s
        expected = type.name.to_s
        if html_document?(element)
          actual.downcase == expected.downcase
        else
          actual == expected
        end
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
        when "^=" then actual.start_with?(expected)
        when "$=" then actual.end_with?(expected)
        when "*=" then actual.include?(expected)
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
        when "active", "visited" then false
        when "target" then element.get_attribute("id").to_s == Internal.target_id(element.owner_document).to_s && !Internal.target_id(element.owner_document).nil?
        when "lang" then lang_match?(element, pseudo.argument)
        when "link" then link_element?(element)
        when "any-link" then link_element?(element)
        else
          false
        end
      end

      def has_relative?(element, relative_selectors, scope:)
        relative_selectors.any? do |relative|
          relative_candidates(element, relative.leading_combinator).any? do |candidate|
            matches_complex?(candidate, relative.complex, scope: scope || element)
          end
        end
      end

      def relative_candidates(element, combinator)
        case combinator
        when :child
          element.children.to_a
        when :next_sibling
          [element.next_element_sibling].compact
        when :subsequent_sibling
          out = []
          sib = element.next_element_sibling
          while sib
            out << sib
            sib = sib.next_element_sibling
          end
          out
        else
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

      def query_root(root, scope)
        return root if root.is_a?(Document) || root.is_a?(ShadowRoot) || root.is_a?(Fragment)
        return root if root.respond_to?(:parent_node) && root.parent_node.nil?

        scope&.owner_document || root
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

      def lang_match?(element, lang)
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

        expected = lang.to_s.downcase
        actual == expected || actual.start_with?("#{expected}-")
      end

      def link_element?(element)
        %w[a area link].include?(element.local_name.to_s.downcase) && element.has_attribute?("href")
      end
    end
  end
end
