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
        Parser.fragment(html.to_s).to_html.gsub(/\s+/, " ").strip
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

      # Visibility check. Fast HTML-level signals first (`hidden` attribute,
      # `<input type=hidden>`, non-rendering ancestors, inline
      # `display:none` / `visibility:hidden`); when the document carries
      # author CSS and the makiri-backed parser is available, stylesheet-
      # driven `display:none` / `visibility:hidden` (e.g. via a class) is
      # detected through the computed style as well. No layout: geometry-
      # dependent invisibility stays out of scope.
      def visible?(element)
        return true unless element.respond_to?(:__dommy_backend_node__)

        node = element.__dommy_backend_node__
        return false if node_invisible_self?(node)

        NodeTraversal.each_ancestor(node) do |ancestor|
          return false if non_rendering_tag?(ancestor)
          return false if node_invisible_self?(ancestor)
        end

        css_visible?(element)
      end

      # CSS-aware extension of visible?, consulted only when the document
      # has author CSS (Cascade.author_css? keeps sheetless documents on the
      # fast path). `display: none` on the element or any ancestor hides;
      # computed `visibility: hidden/collapse` (inherited, overridable by a
      # descendant's `visibility: visible`) hides.
      def css_visible?(element)
        document = element.respond_to?(:owner_document) ? element.owner_document : nil
        return true unless document && CSS::Cascade.author_css?(document)

        return false if %w[hidden collapse].include?(CSS::Cascade.computed_style(element)["visibility"])

        current = element
        while current
          styles = CSS::Cascade.computed_style(current)
          return false if styles["display"] == "none"
          # Zero effective opacity is invisible (Selenium's displayed
          # algorithm); a zero anywhere in the chain zeroes the product.
          return false if opacity_zero?(styles["opacity"])
          current = current.respond_to?(:parent_element) ? current.parent_element : nil
        end

        true
      end

      # `opacity: 0` hides (Selenium's displayed algorithm), and so does any
      # value that computes to 0 — the property clamps to [0, 1], so a negative
      # one is 0 too. One number grammar, read by both the computed-value check
      # above and the inline-style scan below, which used to disagree about
      # `opacity: -1`.
      OPACITY_NUMBER = /[+-]?(?:\d+(?:\.\d*)?|\.\d+)%?/
      INLINE_OPACITY = /opacity\s*:\s*(#{OPACITY_NUMBER})\s*(?:[;!]|\z)/i

      def opacity_zero?(value)
        text = value.to_s.strip
        return false unless text.match?(/\A#{OPACITY_NUMBER}\z/o)

        text.to_f <= 0
      end

      # The same question asked of a raw `style` attribute. Public because
      # dommy-rack asks it too, of elements this module never sees; it used to
      # reach for the regex constant instead, which broke the moment the two
      # opacity grammars were unified here.
      def inline_opacity_zero?(style_text)
        match = style_text.match(INLINE_OPACITY)
        match && opacity_zero?(match[1])
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
        style.match?(/display\s*:\s*none/i) ||
          style.match?(/visibility\s*:\s*hidden/i) ||
          # Inline zero opacity hides too — the same number grammar as the
          # CSS-aware check, so the fast path cannot answer differently.
          inline_opacity_zero?(style)
      end

      # Tags a browser never renders — neither the box nor the text inside it.
      # One list: an element that is invisible and one whose text does not count
      # as page text are the same element.
      NON_RENDERED_TAGS = %w[head script style template noscript].freeze

      def non_rendering_tag?(node)
        node.respond_to?(:name) && NON_RENDERED_TAGS.include?(node.name)
      end

      # Visible text of a node's subtree: like `text_content`, but excluding
      # subtrees that never render (script/style/head/template/noscript).
      # Mirrors what a browser exposes to `has_text?` / text filters, so JSON
      # embedded in a `<script data-page>` (Inertia/Turbo) or inline CSS is not
      # mistaken for visible page text.
      def rendered_text(node)
        return "" if node.nil?

        out = +""
        append_rendered_text(node, out)
        out
      end

      def append_rendered_text(node, out)
        return unless node.respond_to?(:child_nodes)

        node.child_nodes.each do |child|
          # Element wrappers don't expose node_type as a Ruby method (it lives
          # on the JS bridge), so branch on class: recurse into rendered
          # elements, take character data verbatim, skip comments.
          if child.is_a?(Dommy::Element)
            next if NON_RENDERED_TAGS.include?(child.local_name.to_s.downcase)

            append_rendered_text(child, out)
          elsif child.respond_to?(:node_type) && child.node_type == Dommy::Node::TEXT_NODE
            out << child.text_content.to_s
          end
        end
      end

      private_class_method :node_invisible_self?, :non_rendering_tag?, :append_rendered_text, :opacity_zero?
    end
  end
end
