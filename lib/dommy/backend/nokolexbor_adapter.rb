# frozen_string_literal: true

require "nokolexbor"

module Dommy
  module Backend
    # Nokolexbor (Lexbor-based) backend. 3-7× faster CSS selectors,
    # 6× faster HTML5 parsing. HTML-only — XML namespaces are not
    # tracked, so SVG detection falls back to ancestor walking.
    module Nokolexbor
      # Class references for `is_a?` / type-checking.
      Element = ::Nokolexbor::Element
      Document = ::Nokolexbor::Document
      Text = ::Nokolexbor::Text
      Comment = ::Nokolexbor::Comment
      DocumentFragment = ::Nokolexbor::DocumentFragment
      Node = ::Nokolexbor::Node

      # Fake "namespace" wrapper returned for nodes inside <svg> subtrees.
      # Provides the same `href` API that Nokogiri's Namespace object has,
      # so calling code can treat them uniformly.
      SvgNamespace = Struct.new(:href) do
        def initialize
          super("http://www.w3.org/2000/svg")
        end
      end

      SVG_NAMESPACE = SvgNamespace.new.freeze

      module_function

      def parse(html)
        ::Nokolexbor.parse(html.to_s)
      end

      def fragment(html, owner_doc:)
        ::Nokolexbor::DocumentFragment.parse(html.to_s)
      end

      def create_element(name, doc)
        ::Nokolexbor::Node.new(name, doc)
      end

      def create_text(content, doc)
        ::Nokolexbor::Text.new(content, doc)
      end

      def create_comment(content, doc)
        # Nokolexbor's argument order is (content, doc).
        ::Nokolexbor::Comment.new(content, doc)
      end

      # Nokolexbor doesn't track XML namespaces. We synthesize one for
      # SVG by walking ancestors — necessary so `element_class_for`
      # routes SVG tags to their specialized classes.
      def namespace_of(node)
        return nil unless node.respond_to?(:name)

        in_svg_subtree?(node) ? SVG_NAMESPACE : nil
      end

      def add_namespace_definition(_node, _prefix, _href)
        # No-op: Nokolexbor doesn't support XML namespaces.
      end

      # Internal helper — visible to allow testing.
      def in_svg_subtree?(node)
        return true if node.name.to_s.downcase == "svg"

        current = node.parent
        while current
          return true if current.respond_to?(:name) && current.name.to_s.downcase == "svg"
          current = current.respond_to?(:parent) ? current.parent : nil
        end

        false
      end
    end
  end
end
