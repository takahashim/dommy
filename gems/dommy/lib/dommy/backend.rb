# frozen_string_literal: true

module Dommy
  # `Dommy::Backend` — pluggable HTML parser abstraction. Lets Dommy
  # work with either Nokogiri (mature, full namespace support) or
  # Nokolexbor (faster, HTML5-only). Internally, all DOM library
  # code goes through this facade rather than referencing the parser
  # directly.
  #
  # Defaults to Nokogiri if available, else Nokolexbor.
  #
  # Switching backends:
  #
  #   require "dommy"
  #   Dommy::Backend.use(:nokolexbor)
  #
  # Or set directly:
  #
  #   Dommy::Backend.current = Dommy::Backend::Nokolexbor
  #
  # All adapters must implement the same interface — see
  # `Backend::Nokogiri` for the canonical reference.
  module Backend
    class BackendNotAvailable < StandardError
    end

    class << self
      def current
        @current ||= detect_default
      end

      attr_writer :current

      def use(name)
        @current = case name.to_sym
        when :nokogiri
          require_relative "backend/nokogiri_adapter"
          Nokogiri
        when :nokolexbor
          require_relative "backend/nokolexbor_adapter"
          Nokolexbor
        else
          raise ArgumentError, "Unknown backend: #{name.inspect}. Use :nokogiri or :nokolexbor."
        end
      end

      # Delegate calls so internal code can use `Backend.parse(...)`.
      def parse(html)
        current.parse(html)
      end

      # Parse XML input into an XML document. Backends without a real XML parser
      # (HTML-only, e.g. Nokolexbor) fall back to the HTML parser.
      def parse_xml(xml)
        current.respond_to?(:parse_xml) ? current.parse_xml(xml) : current.parse(xml)
      end

      def fragment(html, owner_doc:)
        current.fragment(html, owner_doc: owner_doc)
      end

      def create_element(name, doc)
        current.create_element(name, doc)
      end

      def create_text(content, doc)
        current.create_text(content, doc)
      end

      def create_comment(content, doc)
        current.create_comment(content, doc)
      end

      def namespace_of(node)
        current.namespace_of(node)
      end

      def add_namespace_definition(node, prefix, href)
        current.add_namespace_definition(node, prefix, href)
      end

      # Namespaced attribute access (DOM *AttributeNS). `namespace` is an href
      # String or nil. Nokolexbor degrades to qualified-name (null-namespace).
      def get_attribute_ns(node, namespace, local_name)
        current.get_attribute_ns(node, namespace, local_name)
      end

      def set_attribute_ns(node, namespace, prefix, local_name, qualified_name, value)
        current.set_attribute_ns(node, namespace, prefix, local_name, qualified_name, value)
      end

      def remove_attribute_ns(node, namespace, local_name)
        current.remove_attribute_ns(node, namespace, local_name)
      end

      def has_attribute_ns?(node, namespace, local_name)
        current.has_attribute_ns?(node, namespace, local_name)
      end

      # Reads a backend attribute node into {namespace_uri:, prefix:,
      # local_name:, qualified_name:, value:} (namespace-aware).
      def attribute_ns_info(attr_node)
        current.attribute_ns_info(attr_node)
      end

      # The element's attribute nodes (each readable via attribute_ns_info).
      # The single choke point so DOM code doesn't touch parser internals.
      def attribute_nodes(node)
        current.attribute_nodes(node)
      end

      # Type constants — proxy through to the current backend so
      # `node.is_a?(Backend::Element)` resolves dynamically.
      def element_class
        current::Element
      end

      def document_class
        current::Document
      end

      def text_class
        current::Text
      end

      def comment_class
        current::Comment
      end

      def document_fragment_class
        current::DocumentFragment
      end

      def node_class
        current::Node
      end

      private

      def detect_default
        try_nokogiri ||
          try_nokolexbor ||
          raise(BackendNotAvailable, "Dommy requires either 'nokogiri' or 'nokolexbor' gem to be installed.")
      end

      def try_nokogiri
        require "nokogiri"

        require_relative "backend/nokogiri_adapter"
        Nokogiri
      rescue LoadError
        nil
      end

      def try_nokolexbor
        require "nokolexbor"

        require_relative "backend/nokolexbor_adapter"
        Nokolexbor
      rescue LoadError
        nil
      end
    end
  end
end
