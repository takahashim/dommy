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

      # Custom CSS pseudo-class handlers — a Nokogiri-specific mechanism for
      # selectors its CSS→XPath compiler can't evaluate on its own
      # (`:disabled`/`:enabled`/`:checked`). Nokogiri calls the method named
      # after the pseudo-class with the current node list and expects the
      # filtered list back; it receives raw backend nodes, not Dommy wrappers.
      class PseudoHandlers < BasicObject
        include ::Kernel

        def disabled(list)
          list.find_all { |node| node.has_attribute?("disabled") }
        end

        def enabled(list)
          list.find_all { |node| !node.has_attribute?("disabled") }
        end

        def checked(list)
          list.find_all { |node| node.has_attribute?("checked") }
        end
      end

      # Adds `:scope` support. Nokogiri compiles `:scope` into a custom XPath
      # function `nokogiri:scope(.)`, calling it as `scope(node_set)`; a scoped
      # query (`el.querySelector(":scope > p")`) resolves it to the context
      # element, so only that element matches. One instance per query — it
      # carries the context node.
      class ScopedPseudoHandlers < PseudoHandlers
        def initialize(scope_node)
          @scope_node = scope_node
        end

        def scope(list)
          list.find_all { |node| node.pointer_id == @scope_node.pointer_id }
        end
      end

      DEFAULT_PSEUDO_HANDLERS = PseudoHandlers.new

      module_function

      # libxml2 caches one Ruby wrapper per C node, so object_id is a stable
      # identity; a removed node may be freed and its pointer recycled, which
      # would make a pointer-based key collide, so object_id is the safe choice.
      def identity_key(node)
        node.object_id
      end

      # Deep dup preserves namespace and attributes (createElement would drop the
      # namespace); for a shallow clone we keep that node but drop its subtree.
      def clone_node(node, deep:)
        copy = node.dup(1)
        copy.children.each(&:unlink) unless deep
        copy
      end

      def clone_document(doc)
        doc.dup
      end

      def empty_document
        Document.new
      end

      # Adding `node` under another document's tree makes libxml2 reassign its
      # `document`; we attach transiently then unlink so it ends up free-floating
      # but owned by `target_doc`, with Ruby identity preserved.
      def adopt(node, target_doc)
        target_doc.root.add_child(node)
        node.unlink
        node
      end

      # CSS query honoring Dommy's custom pseudo-classes. `scope_node`, when
      # given, binds `:scope` to that element (for `closest`/scoped queries).
      def select_all(node, selector, scope_node: nil)
        node.css(selector, pseudo_handlers(scope_node))
      end

      def select_first(node, selector, scope_node: nil)
        node.at_css(selector, pseudo_handlers(scope_node))
      end

      def pseudo_handlers(scope_node)
        scope_node ? ScopedPseudoHandlers.new(scope_node) : DEFAULT_PSEUDO_HANDLERS
      end

      def parse(html)
        ::Nokogiri::HTML5(html.to_s, max_errors: 0)
      end

      # Parse an XML string into an XML document (DOMParser "text/xml" etc.).
      def parse_xml(xml)
        ::Nokogiri::XML(xml.to_s)
      end

      def set_document_root(doc, node)
        doc.root = node
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

      def create_cdata(content, doc)
        ::Nokogiri::XML::CDATA.new(doc, content.to_s)
      end

      def cdata_class = ::Nokogiri::XML::CDATA

      def namespace_of(node)
        node.namespace
      end

      def namespace_definitions(node)
        node.namespace_definitions
      end

      # Nokogiri's HTML5 parser keeps <template> contents as normal children.
      def template_content_nodes(node)
        node.children.to_a
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
        # WHATWG "set an attribute value": when an attribute with this
        # (namespace, localName) already exists, only its value changes —
        # the existing prefix/qualified name is preserved, not replaced by
        # the one in this call.
        existing = find_attr_ns(node, namespace, local_name)
        if existing
          existing.value = value.to_s
          return value.to_s
        end

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

      def attribute_nodes(node)
        node.attribute_nodes
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
