# frozen_string_literal: true

module Dommy
  module Internal
    # Shared matching primitives used by both RSpec matchers and
    # Minitest assertions. Centralizes selector / text / count
    # interpretation so the two frameworks behave identically.
    module DomMatching
      module_function

      # Find elements in scope matching selector, optionally filtered
      # by text content.
      #
      # @param scope [#query_selector_all] Document / Element / ShadowRoot / Fragment
      # @param selector [String]
      # @param text [String, Regexp, nil]
      # @return [Array<Dommy::Element>]
      def filter(scope, selector, text: nil)
        elements = scope.query_selector_all(selector).to_a
        return elements if text.nil?

        elements.select { |el| text_matches?(el.text_content, text) }
      end

      # @param actual [String]
      # @param expected [String, Regexp]
      # @param exact [Boolean] when true, require exact equality (string)
      #   or full-string regexp match.
      def text_matches?(actual, expected, exact: false)
        actual = actual.to_s
        case expected
        when Regexp
          exact ? actual.match?(expected) && actual == actual[expected] : actual.match?(expected)
        else
          exact ? actual.strip == expected.to_s : actual.include?(expected.to_s)
        end
      end

      # @param actual [Integer]
      # @param expected [Integer, Range, nil] — nil means "at least one"
      def count_matches?(actual, expected)
        case expected
        when nil
          actual.positive?
        when Integer
          actual == expected
        when ::Range
          expected.cover?(actual)
        else
          false
        end
      end

      # Normalize an HTML string for structural comparison.
      # Re-parses through Nokogiri and re-serializes, which collapses
      # whitespace differences and attribute ordering quirks.
      #
      # @param html [String]
      def normalize_html(html)
        Backend.fragment(html.to_s, owner_doc: nil).to_html.gsub(/\s+/, " ").strip
      end

      # Get the text_content of a scope, handling Document (which has
      # no text_content directly — its body does).
      def text_of(scope)
        if scope.respond_to?(:text_content)
          scope.text_content.to_s
        elsif scope.respond_to?(:body) && scope.body
          scope.body.text_content.to_s
        else
          scope.to_s
        end
      end

      # Get the inner_html of a scope, falling back to body for Document.
      def html_of(scope)
        if scope.respond_to?(:inner_html)
          scope.inner_html.to_s
        elsif scope.respond_to?(:body) && scope.body
          scope.body.inner_html.to_s
        else
          scope.to_s
        end
      end

      # Best-effort visibility check using HTML-level signals only.
      # Does NOT evaluate CSS stylesheets — `display: none` via class
      # is NOT detected. See README for details and workarounds.
      #
      # Detects: `hidden` attribute, `<input type=hidden>`, non-rendering
      # ancestors (head/script/style/template), inline `display:none` /
      # `visibility:hidden` on element or any ancestor.
      def visible?(element)
        return true unless element.respond_to?(:__dommy_backend_node__)

        node = element.__dommy_backend_node__
        return false if node_invisible_self?(node)

        NodeTraversal.each_ancestor(node) do |ancestor|
          return false if non_rendering_tag?(ancestor)
          return false if node_invisible_self?(ancestor)
        end

        true
      end

      # Filter elements by Capybara-style :visible option.
      # @param elements [Array]
      # @param visible [:visible, :all, :hidden, true, false, nil]
      def filter_by_visibility(elements, visible)
        case visible
        when nil, :all, false
          elements
        when :hidden
          elements.reject { |el| visible?(el) }
        else
          elements.select { |el| visible?(el) }
        end
      end

      # ----- Implementation details for visible? -----
      # @api private (kept module-level only because visible? calls them)

      def node_invisible_self?(node)
        return false unless node.respond_to?(:[])

        return true if node["hidden"]
        return true if node.respond_to?(:name) && node.name == "input" && node["type"] == "hidden"

        style = node["style"].to_s
        style.match?(/display\s*:\s*none/i) || style.match?(/visibility\s*:\s*hidden/i)
      end

      def non_rendering_tag?(node)
        node.respond_to?(:name) && %w[head script style template].include?(node.name)
      end

      private_class_method :node_invisible_self?, :non_rendering_tag?
    end
  end
end
