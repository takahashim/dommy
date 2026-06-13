# frozen_string_literal: true

module Dommy
  # `Dommy::Backend` — pluggable HTML parser abstraction. Lets Dommy
  # work with Makiri (Lexbor-based, HTML5-only). Internally, all DOM library
  # code goes through this facade rather than referencing the parser
  # directly.
  #
  # Defaults to Makiri.
  #
  # Switching backends:
  #
  #   require "dommy"
  #   Dommy::Backend.use(:makiri)
  #
  # Or set directly:
  #
  #   Dommy::Backend.current = Dommy::Backend::Makiri
  #
  # All adapters must implement the same interface — see
  # `Backend::Makiri` for the canonical reference.
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
        when :makiri
          require_relative "backend/makiri_adapter"
          Makiri
        else
          raise ArgumentError, "Unknown backend: #{name.inspect}. Use :makiri."
        end
      end

      # Stable per-document identity key for a backend node, used to cache DOM
      # wrappers and key per-node side tables. Makiri mints a fresh wrapper per traversal
      # but never frees nodes (arena-owned), so it keys on the stable node pointer.
      def identity_key(node)
        current.identity_key(node)
      end

      # Deep (or shallow) copy of an element/node, detached and owned by the
      # same document — the backing for DOM cloneNode.
      def clone_node(node, deep:)
        current.clone_node(node, deep: deep)
      end

      # Deep copy of a whole document (DOM cloneNode on the document).
      def clone_document(doc)
        current.clone_document(doc)
      end

      # A fresh, empty backing document (shallow document clone / new Document).
      def empty_document
        current.empty_document
      end

      # Bring `node` (already detached from its old tree) into `target_doc`,
      # returning the backend node now owned by `target_doc`. Makiri can't move a node
      # between arenas, so it imports a copy — callers must reseat any wrapper
      # onto the returned node.
      def adopt(node, target_doc)
        current.adopt(node, target_doc)
      end

      # Whether the backend can move a node between documents in place or must adopt a copy first
      # (Lexbor's arenas can't move a node, so inserting a foreign node requires importing
      # it). Lets callers skip a needless — and on an empty target, root-less and
      # therefore crashing — adoption on backends that don't need it.
      def moves_nodes_across_documents?
        current.respond_to?(:moves_nodes_across_documents?) ? current.moves_nodes_across_documents? : true
      end

      # CSS query that honors Dommy's custom pseudo-classes
      # (`:disabled`/`:enabled`/`:checked`/`:scope`). Each backend applies its
      # own mechanism (Lexbor native pseudos plus a
      # `:scope` rewrite). `scope_node` binds `:scope` to that element.
      def select_all(node, selector, scope_node: nil)
        current.select_all(node, selector, scope_node: scope_node)
      end

      def select_first(node, selector, scope_node: nil)
        current.select_first(node, selector, scope_node: scope_node)
      end

      # Delegate calls so internal code can use `Backend.parse(...)`.
      def parse(html)
        current.parse(html)
      end

      # Parse XML input into an XML document.
      # fall back to the HTML parser.
      def parse_xml(xml)
        current.parse_xml(xml)
      end

      def fragment(html, owner_doc:)
        current.fragment(html, owner_doc: owner_doc)
      end

      # Make `node` the sole document element of `doc` (used by
      # DOMImplementation.createDocument). Lexbor-backed documents are seeded with an <html> shell
      # that must be cleared first.
      def set_document_root(doc, node)
        current.set_document_root(doc, node)
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

      # CDATA section node (XML documents). Backends without CDATA fall back to a
      # text node.
      def create_cdata(content, doc)
        current.respond_to?(:create_cdata) ? current.create_cdata(content, doc) : current.create_text(content, doc)
      end

      def cdata_class
        current.respond_to?(:cdata_class) ? current.cdata_class : nil
      end

      # ProcessingInstruction node (`<?target data?>`). Supported by every
      # backend Dommy ships (both Makiri document families), so — unlike CDATA —
      # there is no text-node fallback.
      def create_processing_instruction(target, data, doc)
        current.create_processing_instruction(target, data, doc)
      end

      def processing_instruction_class
        current.processing_instruction_class
      end

      def namespace_of(node)
        current.namespace_of(node)
      end

      # The element's in-scope namespace declarations (each responds to
      # `prefix`/`href`). Empty on backends without an XML namespace model.
      def namespace_definitions(node)
        current.namespace_definitions(node)
      end

      # The content child nodes of a `<template>` element. HTML5 parsers model
      # template contents differently — Lexbor/Makiri in a separate content fragment — so reading them goes
      # through the backend. Used by the template-content registry's migration.
      def template_content_nodes(node)
        current.template_content_nodes(node)
      end

      def add_namespace_definition(node, prefix, href)
        current.add_namespace_definition(node, prefix, href)
      end

      # Namespaced attribute access (DOM *AttributeNS). `namespace` is an href
      # String or nil.
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
        try_makiri ||
          raise(BackendNotAvailable, "Dommy requires either 'makiri' gem to be installed.")
      end

      def try_makiri
        require "makiri"

        require_relative "backend/makiri_adapter"
        Makiri
      rescue LoadError
        nil
      end
    end
  end
end
