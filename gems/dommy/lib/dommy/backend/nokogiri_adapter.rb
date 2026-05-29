# frozen_string_literal: true

require "nokogiri"

module Dommy
  module Backend
    # Nokogiri (libxml2-based) backend. Mature, full XML namespace
    # support. Default backend.
    module Nokogiri
      # Class references for `is_a?` / type-checking from Dommy internals.
      Element = ::Nokogiri::XML::Element
      Document = ::Nokogiri::XML::Document
      Text = ::Nokogiri::XML::Text
      Comment = ::Nokogiri::XML::Comment
      DocumentFragment = ::Nokogiri::XML::DocumentFragment
      Node = ::Nokogiri::XML::Node

      module_function

      def parse(html)
        ::Nokogiri::HTML5(html.to_s, max_errors: 0)
      end

      def fragment(html, owner_doc:)
        # owner_doc is unused by Nokogiri — the fragment carries its
        # own document. The Parser layer copies nodes into the target.
        ::Nokogiri::HTML5.fragment(html.to_s, max_errors: 0)
      end

      def create_element(name, doc)
        ::Nokogiri::XML::Node.new(name, doc)
      end

      def create_text(content, doc)
        ::Nokogiri::XML::Text.new(content, doc)
      end

      def create_comment(content, doc)
        ::Nokogiri::XML::Comment.new(doc, content)
      end

      def namespace_of(node)
        node.namespace
      end

      def add_namespace_definition(node, prefix, href)
        node.add_namespace_definition(prefix, href)
      end
    end
  end
end
