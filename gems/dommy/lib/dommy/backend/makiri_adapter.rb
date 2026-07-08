# frozen_string_literal: true

require "makiri"

module Dommy
  module Backend
    # Makiri (Lexbor-based) backend. HTML5 parsing and CSS selectors via
    # Lexbor, plus a native XPath 1.0 engine, with no libxml2 dependency.
    # Makiri splits its document model into `Makiri::HTML::Document` (case-folding,
    # html/head/body) and `Makiri::XML::Document` (case-preserving, namespaces,
    # CDATA); both share the `Makiri::Document` / `Makiri::Node` bases used here
    # for `is_a?` checks. HTML parses go through HTML::Document; `new Document()` /
    # createDocument go through XML::Document.
    module Makiri
      # Class references for `is_a?` / type-checking (the shared bases, so both
      # HTML and XML node subclasses match).
      Element = ::Makiri::Element
      Document = ::Makiri::Document
      Text = ::Makiri::Text
      Comment = ::Makiri::Comment
      CDATASection = ::Makiri::CDATASection
      ProcessingInstruction = ::Makiri::ProcessingInstruction
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
      # document reproduces the full tree. Dispatch on the document kind so an XML
      # document round-trips through the XML parser (case/namespaces/CDATA) and an
      # HTML document through the HTML parser.
      def clone_document(doc)
        if doc.is_a?(::Makiri::XML::Document)
          ::Makiri::XML::Document.parse(doc.to_xml)
        else
          ::Makiri::HTML::Document.parse(doc.to_html)
        end
      end

      # A fresh, empty HTML-backed document (children dropped so it starts with no
      # documentElement). The backing for a shallow clone of an HTML document.
      def empty_document
        doc = ::Makiri::HTML::Document.parse("")
        doc.children.to_a.each(&:unlink)
        doc
      end

      # A fresh, empty XML-backed document — the backing for `new Document()` /
      # createDocument, which the DOM defines as XML documents. An XML backing
      # gives them case preservation, real CDATA nodes (nodeType 4) and namespace
      # tracking. Makiri's cross-kind `import_node` translates between the HTML and
      # XML node representations, so a node created here can still be adopted into
      # the main HTML tree (and vice versa) — which is why an XML backing no longer
      # blocks the cross-tree inserts WPT performs.
      def empty_xml_document
        ::Makiri::XML::Document.new
      end

      # An empty document matching `doc`'s kind, for a shallow document clone
      # (cloneNode(false) on a document must keep the same flavor).
      def empty_document_like(doc)
        doc.is_a?(::Makiri::XML::Document) ? empty_xml_document : empty_document
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
      #
      # Gap absorption: Lexbor's HTML serializer has no CDATA case (it errors on a
      # CDATA node) and Lexbor is a pinned upstream submodule, so Makiri's
      # cross-kind import_node fails closed when bringing an XML CDATASection into
      # an HTML document. Rather than let that surface as an error, degrade the
      # node to a text node carrying the same data — the data a spec-faithful HTML
      # serializer emits anyway (CDATASection is a Text subtype). The caller
      # reseats the Dommy CDATASection wrapper onto this node, so `nodeType`
      # stays 4 at the DOM level; only the backing node (and thus serialization)
      # is text. An XML target keeps a real CDATA node. This handles a directly
      # adopted CDATA node (a CDATA descendant inside an adopted element subtree
      # is rare, untested, and still fails closed in the backend).
      def adopt(node, target_doc)
        if node.is_a?(::Makiri::CDATASection) && !target_doc.is_a?(::Makiri::XML::Document)
          return target_doc.create_text_node(node.text)
        end

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
        ::Makiri::HTML::Document.parse(html.to_s)
      end

      # XML parse (DOMParser `text/xml` / `application/xml`): a real XML document,
      # so element/attribute case is preserved, namespaces are tracked, and CDATA
      # round-trips. The parsed tree is self-contained (not mixed into the HTML
      # tree), so the HTML/XML node-kind split doesn't bite here.
      def parse_xml(xml)
        ::Makiri::XML::Document.parse(xml.to_s)
      end

      def fragment(html, owner_doc:)
        ::Makiri::DocumentFragment.parse(html.to_s)
      end

      def create_element(name, doc)
        # Mint from the owning document so HTML docs lower-case the name and XML
        # docs preserve its case.
        doc.create_element(name)
      end

      # An XML-backed document rejects a qualified name that DOM allows (e.g.
      # "f}oo" — an invalid char in the local part), so createElementNS uses
      # Makiri's loose creator, which builds it verbatim (case/prefix preserved).
      # nil for a non-XML backend → the caller uses the strict #create_element.
      def create_element_loose(qualified_name, prefix, local, namespace, doc)
        return nil unless doc.is_a?(::Makiri::XML::Document) && doc.respond_to?(:create_loose_dom_element)

        doc.create_loose_dom_element(qualified_name, prefix, local, namespace)
      end

      def create_text(content, doc)
        doc.create_text_node(content)
      end

      def create_comment(content, doc)
        doc.create_comment(content)
      end

      # CDATASection (nodeType 4). A genuine XML document — including a
      # `new Document()` / createDocument document, now XML-backed (see
      # #empty_xml_document) — mints a real CDATA node and the XML serializer emits
      # `<![CDATA[…]]>`. `Document#create_cdata_section` rejects HTML documents up
      # front (NotSupportedError, per spec), so the text-node fallback below is a
      # defensive guard for any non-XML backend that still slips through (Lexbor's
      # HTML serializer raises on a native CDATA node, so a text node keeps
      # serialization safe).
      def create_cdata(content, doc)
        if doc.is_a?(::Makiri::XML::Document)
          doc.create_cdata(content)
        else
          doc.create_text_node(content)
        end
      end

      # The backend class for a CDATA node, so the wrapper routes it to
      # CDATASectionNode (it is a Text subtype, matched before Text).
      def cdata_class
        ::Makiri::CDATASection
      end

      # Both Makiri document families (HTML and XML) mint a real PI node and
      # serialize it (HTML as `<?target data>`, XML as `<?target data?>`), so PIs
      # — unlike CDATA — need no HTML-document fallback.
      def create_processing_instruction(target, data, doc)
        doc.create_processing_instruction(target, data)
      end

      def processing_instruction_class
        ::Makiri::ProcessingInstruction
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

      # Bind a *prefixed* element's namespace so the prefix resolves. An XML
      # document resolves an element's prefix from xmlns declarations at insertion
      # time, so a prefixed element (createElementNS / createDocument with a
      # qualified name like "foo:div") must carry an xmlns:prefix declaration or
      # the insert fails with an unbound-prefix error. The namespaceURI itself is
      # tracked on the Dommy wrapper, so the unprefixed case needs nothing here —
      # and must add no attribute, lest a spurious xmlns surface in the DOM view
      # (attributes/isEqualNode). An HTML (Lexbor) document tracks the namespace
      # natively and needs no declaration either. (This was a blanket no-op back
      # when new Document()/createDocument were HTML-backed; XML-backing them
      # surfaced the prefixed-element gap.)
      def add_namespace_definition(node, prefix, href)
        return if prefix.nil? || prefix.empty?
        return unless node.document.is_a?(::Makiri::XML::Document)

        node["xmlns:#{prefix}"] = href.to_s
        nil
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
        # Remove by (namespace, local name) — removing by qualified name is
        # ambiguous once same-name/different-namespace attributes coexist.
        node.remove_attribute_ns(presence(namespace), local_name.to_s)
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
