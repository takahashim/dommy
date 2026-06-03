# frozen_string_literal: true

require "makiri"

module Dommy
  module Backend
    # Makiri (Lexbor-based) backend. HTML5 parsing and CSS selectors via
    # Lexbor, plus a native XPath 1.0 engine, with no libxml2 dependency.
    # HTML-only — XML namespaces are not tracked, so SVG detection falls
    # back to ancestor walking and *AttributeNS collapses to the qualified
    # name in the null namespace.
    module Makiri
      # Class references for `is_a?` / type-checking.
      Element = ::Makiri::Element
      Document = ::Makiri::Document
      Text = ::Makiri::Text
      Comment = ::Makiri::Comment
      DocumentFragment = ::Makiri::DocumentFragment
      Node = ::Makiri::Node

      # Fake "namespace" wrapper returned for nodes inside <svg> subtrees.
      # Provides the same `href` API that Nokogiri's Namespace object has,
      # so calling code can treat them uniformly.
      SvgNamespace = Struct.new(:href) do
        def initialize
          super("http://www.w3.org/2000/svg")
        end
      end

      SVG_NAMESPACE = SvgNamespace.new.freeze

      # Throwaway attribute used to bind `:scope` to a context element — Lexbor
      # has no `:scope`, so a scoped query temporarily marks the element and
      # rewrites `:scope` to an attribute selector, removing the mark after.
      SCOPE_ATTR = "data-dommy-scope"

      module_function

      # Makiri clones natively (import_node + template fixup), preserving the
      # node's namespace and attributes and carrying <template> contents.
      def clone_node(node, deep:)
        node.clone_node(deep)
      end

      # Makiri documents have no node-level clone; re-parsing the serialized
      # document reproduces the full tree (no fragment-parser unwrapping, since
      # this is a complete document).
      def clone_document(doc)
        ::Makiri::Document.parse(doc.to_html)
      end

      def empty_document
        ::Makiri::Document.parse("")
      end

      # Makiri can't move a node between document arenas, so adoption imports a
      # detached copy owned by `target_doc`. The caller reseats the wrapper onto
      # this returned node, preserving Dommy-level identity.
      def adopt(node, target_doc)
        target_doc.import_node(node, true)
      end

      # CSS query honoring Dommy's custom pseudo-classes. Lexbor handles
      # `:disabled`/`:enabled`/`:checked` natively, so only `:scope` needs help:
      # when `scope_node` is given and the selector uses `:scope`, bind it to
      # that element via a temporary attribute.
      def select_all(node, selector, scope_node: nil)
        with_scope(selector, scope_node) { |sel| node.css(sel) }
      end

      def select_first(node, selector, scope_node: nil)
        with_scope(selector, scope_node) { |sel| node.at_css(sel) }
      end

      def with_scope(selector, scope_node)
        return yield(selector) unless scope_node && selector.include?(":scope")

        scope_node[SCOPE_ATTR] = ""
        begin
          yield(selector.gsub(":scope", "[#{SCOPE_ATTR}]"))
        ensure
          scope_node.remove_attribute(SCOPE_ATTR)
        end
      end

      # Makiri hands out a fresh Ruby wrapper on each traversal, so object_id is
      # not stable; pointer_id (the underlying lxb_dom_node_t pointer) is. Safe
      # as an identity key because Makiri detaches but never frees nodes — the
      # document arena owns them — so a live node's pointer is never recycled.
      def identity_key(node)
        node.pointer_id
      end

      def parse(html)
        ::Makiri::Document.parse(html.to_s)
      end

      def fragment(html, owner_doc:)
        ::Makiri::DocumentFragment.parse(html.to_s)
      end

      def create_element(name, doc)
        # Makiri's Element.new(name, document) delegates to create_element.
        ::Makiri::Element.new(name, doc)
      end

      def create_text(content, doc)
        ::Makiri::Text.new(content, doc)
      end

      def create_comment(content, doc)
        # Makiri has no Comment.new; comments are minted from the document.
        doc.create_comment(content)
      end

      # Makiri doesn't track XML namespaces. We synthesize one for SVG by
      # walking ancestors — necessary so `element_class_for` routes SVG
      # tags to their specialized classes.
      def namespace_of(node)
        return nil unless node.respond_to?(:name)

        in_svg_subtree?(node) ? SVG_NAMESPACE : nil
      end

      def add_namespace_definition(_node, _prefix, _href)
        # No-op: Makiri doesn't support XML namespaces.
      end

      def namespace_definitions(_node)
        # Makiri tracks no XML namespace declarations.
        []
      end

      # Lexbor keeps <template> contents in a separate content fragment rather
      # than the normal child chain.
      def template_content_nodes(node)
        cf = node.respond_to?(:content_fragment) ? node.content_fragment : nil
        cf ? cf.children.to_a : []
      end

      # ----- Namespaced attributes (degraded) -----
      # Makiri has no namespace model, so *AttributeNS collapses to the
      # qualified name in the null namespace. Fine for HTML (all attributes are
      # null-namespace); foreign-content (SVG/MathML) fidelity is lost.

      def get_attribute_ns(node, _namespace, local_name)
        node[local_name.to_s]
      end

      def has_attribute_ns?(node, _namespace, local_name)
        node.key?(local_name.to_s)
      end

      def set_attribute_ns(node, _namespace, _prefix, _local_name, qualified_name, value)
        node[qualified_name] = value.to_s
        value.to_s
      end

      def remove_attribute_ns(node, _namespace, local_name)
        node.remove_attribute(local_name.to_s) if node.key?(local_name.to_s)
        nil
      end

      def attribute_ns_info(attr_node)
        {
          namespace_uri: nil,
          prefix: nil,
          local_name: attr_node.name,
          qualified_name: attr_node.name,
          value: attr_node.value,
        }
      end

      def attribute_nodes(node)
        node.attribute_nodes
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
