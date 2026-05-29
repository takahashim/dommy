# frozen_string_literal: true

module Capybara
  module Dommy
    # Extracts text from a Dommy subtree, reusing Capybara's own whitespace
    # normalization so results match the matchers' expectations. `all_text` is
    # the raw textContent; `visible_text` excludes element subtrees that are
    # hidden under the driver's visibility mode or are non-rendered
    # (script/style/head), and inserts breaks at block boundaries.
    class TextExtractor
      include Capybara::Node::WhitespaceNormalizer

      BLOCK_ELEMENTS = %w[
        p h1 h2 h3 h4 h5 h6 ol ul pre address blockquote dl div fieldset form hr noscript table
      ].freeze
      NON_DISPLAYED_ELEMENTS = %w[script style head title].freeze

      def initialize(driver)
        @driver = driver
      end

      def all_text(element)
        normalize_spacing(element.text_content)
      end

      def visible_text(element)
        return "" unless @driver.visible?(element)

        normalize_visible_spacing(displayed_text(element))
      end

      private

      def displayed_text(element)
        element.child_nodes.map do |child|
          if text_node?(child)
            # Whitespace inside a text node (incl. newlines) collapses to
            # spaces; only block boundaries introduce line breaks.
            child.text_content.tr(SQUEEZED_SPACES, " ")
          elsif element_node?(child)
            next "" if non_displayed?(child) || !@driver.visible?(child)

            inner = displayed_text(child)
            block_element?(child) ? "\n#{inner}\n" : inner
          else
            ""
          end
        end.join
      end

      def non_displayed?(node)
        NON_DISPLAYED_ELEMENTS.include?(node.tag_name.downcase)
      end

      def block_element?(node)
        BLOCK_ELEMENTS.include?(node.tag_name.downcase)
      end

      def text_node?(node)
        node.is_a?(::Dommy::TextNode)
      end

      def element_node?(node)
        node.is_a?(::Dommy::Element)
      end
    end
  end
end
