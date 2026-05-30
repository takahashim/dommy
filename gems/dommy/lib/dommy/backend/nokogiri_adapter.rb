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

      # ----- Namespaced attributes -----

      def get_attribute_ns(node, namespace, local_name)
        find_attr_ns(node, namespace, local_name)&.value
      end

      def has_attribute_ns?(node, namespace, local_name)
        !find_attr_ns(node, namespace, local_name).nil?
      end

      def set_attribute_ns(node, namespace, prefix, local_name, qualified_name, value)
        if namespace.nil? || namespace.to_s.empty?
          node[qualified_name] = value.to_s
          return value.to_s
        end

        # Defining the namespace before the qualified-name assignment lets
        # libxml2 bind the prefix to it (verified behavior). Reuse an existing
        # matching definition so repeated sets don't pile up declarations.
        node.namespace_definitions.find { |d| d.href == namespace.to_s && d.prefix == prefix } ||
          node.add_namespace_definition(prefix, namespace.to_s)
        node[qualified_name] = value.to_s
        value.to_s
      end

      def remove_attribute_ns(node, namespace, local_name)
        find_attr_ns(node, namespace, local_name)&.remove
        nil
      end

      def attribute_ns_info(attr_node)
        ns = attr_node.namespace
        {
          namespace_uri: ns&.href,
          prefix: ns&.prefix,
          local_name: attr_node.name,
          qualified_name: ns&.prefix ? "#{ns.prefix}:#{attr_node.name}" : attr_node.name,
          value: attr_node.value,
        }
      end

      # Finds the attribute node matching (namespace, localName). A null
      # namespace matches only the un-namespaced attribute of that local name.
      def find_attr_ns(node, namespace, local_name)
        if namespace.nil? || namespace.to_s.empty?
          node.attribute_nodes.find { |a| a.namespace.nil? && a.name == local_name.to_s }
        else
          node.attribute_with_ns(local_name.to_s, namespace.to_s)
        end
      end
    end
  end
end
