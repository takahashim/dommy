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

      # A minimal namespace wrapper exposing the same `href` API that Nokogiri's
      # Namespace object has, so calling code treats both backends uniformly.
      Namespace = Struct.new(:href)

      HTML_NAMESPACE_URI = "http://www.w3.org/1999/xhtml"

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

      # Lexbor seeds even an empty parse with an <html> shell and has no `root=`,
      # so clear the existing children before adopting `node` as the root.
      def set_document_root(doc, node)
        doc.children.to_a.each(&:unlink)
        doc.add_child(node)
      end

      # Makiri can't move a node between document arenas, so adoption imports a
      # detached copy owned by `target_doc`. The caller reseats the wrapper onto
      # this returned node, preserving Dommy-level identity.
      def adopt(node, target_doc)
        target_doc.import_node(node, true)
      end

      # Lexbor arenas can't move a node between documents — a foreign node must be
      # imported (see #adopt) before insertion.
      def moves_nodes_across_documents?
        false
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
      # The element's namespace, from Lexbor's own namespace tracking (HTML /
      # SVG / MathML). nil for the HTML namespace, so Element#namespace_uri
      # falls back to its HTML default (and the wrapper is allocated only for
      # genuine foreign content).
      def namespace_of(node)
        return nil unless node.respond_to?(:namespace_uri)

        uri = node.namespace_uri
        return nil if uri.nil? || uri.empty? || uri == HTML_NAMESPACE_URI

        Namespace.new(uri)
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

      # ----- Namespaced attributes -----
      # Lexbor (Makiri >= 0.2) tracks the attribute's own namespace: set_attribute_ns
      # records it (splitting prefix/local), and the attr node reports
      # namespace_uri/prefix/local_name. So *AttributeNS matches on (namespace,
      # local name) faithfully.

      def get_attribute_ns(node, namespace, local_name)
        attr_by_ns(node, namespace, local_name)&.value
      end

      def has_attribute_ns?(node, namespace, local_name)
        !attr_by_ns(node, namespace, local_name).nil?
      end

      def set_attribute_ns(node, namespace, _prefix, _local_name, qualified_name, value)
        node.set_attribute_ns(presence(namespace), qualified_name.to_s, value.to_s)
        value.to_s
      end

      def remove_attribute_ns(node, namespace, local_name)
        attr = attr_by_ns(node, namespace, local_name)
        node.remove_attribute(attr.name) if attr
        nil
      end

      def attribute_ns_info(attr_node)
        {
          namespace_uri: presence(attr_node.namespace_uri),
          prefix: presence(attr_node.prefix),
          local_name: attr_node.local_name,
          qualified_name: attr_node.name,
          value: attr_node.value,
        }
      end

      def attribute_nodes(node)
        node.attribute_nodes
      end

      # Attribute node matching (namespace, local name) case-sensitively; a
      # null/empty namespace matches a null-namespace attribute.
      def attr_by_ns(node, namespace, local_name)
        want_ns = presence(namespace)
        want_local = local_name.to_s
        node.attribute_nodes.find do |a|
          a.local_name == want_local && presence(a.namespace_uri) == want_ns
        end
      end

      def presence(value)
        return nil if value.nil?

        s = value.to_s
        s.empty? ? nil : s
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
