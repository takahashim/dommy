# frozen_string_literal: true

require "makiri"

module Dommy
  # `Dommy::Backend` — what the DOM asks of Makiri, the Lexbor-based parser
  # that holds every tree. All DOM library code comes through here rather
  # than reading Makiri's API directly, so what Dommy relies on of it is in
  # one place: the node classes, the creators, the namespaced attribute
  # model, and the few normalizations (an empty namespace is none).
  #
  # Makiri splits its document model into `Makiri::HTML::Document`
  # (case-folding, html/head/body) and `Makiri::XML::Document`
  # (case-preserving, namespaces, CDATA); both share the `Makiri::Document` /
  # `Makiri::Node` bases used here for `is_a?` checks. HTML parses go through
  # HTML::Document; `new Document()` / createDocument go through XML::Document.
  module Backend
    # Throwaway attribute used to bind `:scope` to a context element — Lexbor
    # has no `:scope`, so a scoped query temporarily marks the element and
    # rewrites `:scope` to an attribute selector, removing the mark after.
    SCOPE_ATTR = "data-dommy-scope"

    # Lexbor's document mode: 0 no-quirks, 1 quirks, 2 limited-quirks.
    QUIRKS = 1

    class << self
      # The node classes (the shared bases, so both HTML and XML node
      # subclasses match), so the wrapper cache can route each node.
      def element_class = ::Makiri::Element

      def document_class = ::Makiri::Document

      def text_class = ::Makiri::Text

      def comment_class = ::Makiri::Comment

      # A Text subtype, matched before Text.
      def cdata_class = ::Makiri::CDATASection

      def processing_instruction_class = ::Makiri::ProcessingInstruction

      def document_fragment_class = ::Makiri::DocumentFragment

      def document_type_class = ::Makiri::DocumentType

      def node_class = ::Makiri::Node

      # What Makiri raises for markup that is not well-formed XML (an XML
      # document's fragment parse included).
      def xml_syntax_error_class = ::Makiri::XML::SyntaxError

      # Stable per-document identity key for a backend node, used to key
      # per-node side tables. pointer_id is the underlying lxb_dom_node_t
      # pointer: Makiri detaches but never frees nodes — the document arena
      # owns them — so a live node's pointer is never recycled; a freed
      # document's may be, so a table keyed by it is a document's own.
      def identity_key(node)
        node.pointer_id
      end

      # Deep (or shallow) copy of an element/node, detached and owned by the
      # same document — the backing for DOM cloneNode. Makiri clones natively
      # (import_node + template fixup), preserving the node's namespace and
      # attributes and carrying <template> contents.
      def clone_node(node, deep:)
        node.clone_node(deep)
      end

      # A fresh, empty HTML-backed document (children dropped so it starts
      # with no documentElement). The backing for a shallow clone of an HTML
      # document.
      def empty_document
        doc = ::Makiri::HTML::Document.parse("")
        doc.children.to_a.each(&:unlink)
        doc
      end

      # A fresh, empty XML-backed document — the backing for `new Document()` /
      # createDocument, which the DOM defines as XML documents. An XML backing
      # gives them case preservation, real CDATA nodes (nodeType 4) and
      # namespace tracking. Makiri's cross-kind `import_node` translates
      # between the HTML and XML node representations, so a node created here
      # can still be adopted into the main HTML tree (and vice versa).
      def empty_xml_document
        ::Makiri::XML::Document.new
      end

      # Whether the HTML parser left `doc` in quirks mode (not limited-quirks,
      # which matches no-quirks everywhere Dommy asks).
      def quirks_mode?(doc)
        doc.respond_to?(:quirks_mode) && doc.quirks_mode == QUIRKS
      end

      # An empty backing document matching `doc`'s kind (HTML stays HTML, XML
      # stays XML) — for a shallow document clone, whose result keeps the
      # source flavor.
      def empty_document_like(doc)
        doc.is_a?(::Makiri::XML::Document) ? empty_xml_document : empty_document
      end

      # Bring `node` (already detached from its old tree) into `target_doc`,
      # returning the backend node now owned by `target_doc`. Lexbor's arenas
      # can't move a node between documents, so adoption imports a detached
      # copy — callers must reseat any wrapper onto the returned node.
      #
      # Gap absorption: Lexbor's HTML serializer has no CDATA case (it errors
      # on a CDATA node) and Lexbor is a pinned upstream submodule, so Makiri's
      # cross-kind import_node fails closed when bringing an XML CDATASection
      # into an HTML document. Rather than let that surface as an error,
      # degrade the node to a text node carrying the same data — the data a
      # spec-faithful HTML serializer emits anyway (CDATASection is a Text
      # subtype). The caller reseats the Dommy CDATASection wrapper onto this
      # node, so `nodeType` stays 4 at the DOM level; only the backing node
      # (and thus serialization) is text. An XML target keeps a real CDATA
      # node. This handles a directly adopted CDATA node (a CDATA descendant
      # inside an adopted element subtree is rare, untested, and still fails
      # closed in the backend).
      def adopt(node, target_doc)
        if node.is_a?(::Makiri::CDATASection) && !target_doc.is_a?(::Makiri::XML::Document)
          return target_doc.create_text_node(node.text)
        end

        target_doc.import_node(node, true)
      end

      # A copy of the element `node` alone, owned by `target_doc`: its name and
      # attributes exactly as the backend holds them.
      def import_element(node, target_doc)
        target_doc.import_node(node, false)
      end

      # CSS query honoring Dommy's custom pseudo-classes. Lexbor handles
      # `:disabled`/`:enabled`/`:checked` natively, so only `:scope` needs
      # help: when `scope_node` is given and the selector uses `:scope`, bind
      # it to that element via a temporary attribute.
      def select_all(node, selector, scope_node: nil)
        with_scope(selector, scope_node) { |sel| node.css(sel) }
      end

      def select_first(node, selector, scope_node: nil)
        with_scope(selector, scope_node) { |sel| node.at_css(sel) }
      end

      def parse(html)
        ::Makiri::HTML::Document.parse(html.to_s)
      end

      # XML parse (DOMParser `text/xml` / `application/xml`): a real XML
      # document, so element/attribute case is preserved, namespaces are
      # tracked, and CDATA round-trips.
      def parse_xml(xml)
        ::Makiri::XML::Document.parse(xml.to_s)
      end

      def fragment(html, owner_doc:)
        ::Makiri::DocumentFragment.parse(html.to_s)
      end

      # Make `node` the sole document element of `doc` (used by
      # DOMImplementation.createDocument). Lexbor seeds even an empty parse
      # with an <html> shell and has no `root=`, so clear the existing
      # children before adopting `node` as the root.
      def set_document_root(doc, node)
        doc.children.to_a.each(&:unlink)
        doc.add_child(node)
      end

      # Mint from the owning document so HTML docs lower-case the name and
      # XML docs preserve its case.
      def create_element(name, doc)
        doc.create_element(name)
      end

      # Create a namespaced element permitting a DOM-valid qualified name that
      # a strict XML backend would reject (an internal invalid char like
      # "f}oo"), preserving case/prefix: Makiri's loose creator builds it
      # verbatim. Returns nil for an HTML document (fall back to
      # #create_element); raises ArgumentError for a genuinely invalid name
      # (the caller maps it to InvalidCharacterError).
      def create_element_loose(qualified_name, prefix, local, namespace, doc)
        return nil unless doc.is_a?(::Makiri::XML::Document)

        doc.create_loose_dom_element(qualified_name, prefix, local, namespace)
      end

      # createElementNS in an HTML document. Makiri builds the element in its
      # own namespace, so the backend node is what the parser would have made:
      # an SVG `feGaussianBlur` keeps its case and `[viewBox]` reads its
      # attribute case-sensitively. Returns nil for an XML document (fall back
      # to #create_element); raises ArgumentError for an invalid name (the
      # caller maps it to InvalidCharacterError).
      def create_element_ns(namespace, qualified_name, doc)
        return nil unless doc.is_a?(::Makiri::HTML::Document)

        doc.create_element_ns(presence(namespace), qualified_name.to_s)
      end

      # A detached DocumentType node owned by `doc` (for
      # DOMImplementation.createDocumentType). Only the HTML document ships
      # the factory; nil signals the caller to fall back to a synthetic
      # (non-tree) DocumentType. Raises ArgumentError for a name the factory
      # rejects (the caller then also falls back, since createDocumentType is
      # permissive).
      def create_document_type(name, public_id, system_id, doc)
        return nil unless doc.respond_to?(:create_document_type)

        doc.create_document_type(name.to_s, public_id.to_s, system_id.to_s)
      end

      # The parsed document's DocumentType node (`<!DOCTYPE …>`), or nil when
      # the document declares none.
      def internal_subset(doc)
        doc.respond_to?(:internal_subset) ? doc.internal_subset : nil
      end

      def create_text(content, doc)
        doc.create_text_node(content)
      end

      def create_comment(content, doc)
        doc.create_comment(content)
      end

      # CDATASection (nodeType 4). A genuine XML document — including a
      # `new Document()` / createDocument document, XML-backed (see
      # #empty_xml_document) — mints a real CDATA node and the XML serializer
      # emits `<![CDATA[…]]>`. `Document#create_cdata_section` rejects HTML
      # documents up front (NotSupportedError, per spec), so the text-node
      # fallback below is a defensive guard for an HTML document that still
      # slips through (Lexbor's HTML serializer raises on a native CDATA node,
      # so a text node keeps serialization safe).
      def create_cdata(content, doc)
        if doc.is_a?(::Makiri::XML::Document)
          doc.create_cdata(content)
        else
          doc.create_text_node(content)
        end
      end

      # ProcessingInstruction node (`<?target data?>`). Both Makiri document
      # families mint a real PI node and serialize it, so PIs — unlike CDATA —
      # need no HTML-document fallback.
      def create_processing_instruction(target, data, doc)
        doc.create_processing_instruction(target, data)
      end

      # DOM "child text content": the data of `node`'s Text (and CDATA
      # section) children, in order — no deeper descendant's.
      def child_text_content(node)
        node.children.select { |c| c.text? || c.cdata? }.map(&:content).join
      end

      # The element's own namespace URI as the DOM reports it (Lexbor's HTML /
      # SVG / MathML, an XML document's own), nil for none.
      def namespace_uri(node)
        presence(node.respond_to?(:namespace_uri) ? node.namespace_uri : nil)
      end

      # The element's own namespace prefix as the DOM reports it, nil for none.
      def prefix(node)
        presence(node.prefix)
      end

      # Bind a *prefixed* element's namespace so the prefix resolves. An XML
      # document resolves an element's prefix from xmlns declarations at
      # insertion time, so a prefixed element (createElementNS /
      # createDocument with a qualified name like "foo:div") must carry an
      # xmlns:prefix declaration or the insert fails with an unbound-prefix
      # error. The namespaceURI itself is tracked on the Dommy wrapper, so the
      # unprefixed case needs nothing here — and must add no attribute, lest a
      # spurious xmlns surface in the DOM view (attributes/isEqualNode). An
      # HTML (Lexbor) document tracks the namespace natively and needs no
      # declaration either.
      def add_namespace_definition(node, prefix, href)
        return if prefix.nil? || prefix.empty?
        return unless node.document.is_a?(::Makiri::XML::Document)

        node["xmlns:#{prefix}"] = href.to_s
        nil
      rescue ArgumentError, ::Makiri::Error
        # DOM validates a qualified name against the Name production, which
        # admits prefixes an XML backend cannot spell as an `xmlns:` attribute
        # ("0:a", ";:a" — ArgumentError), and binds prefixes Namespaces in XML
        # forbids declaring ("f" to the XML namespace, anything to the XMLNS
        # one — Makiri::Error). The element is still valid — its prefix and
        # namespace live on the wrapper — so the declaration is simply not
        # written.
        nil
      end

      # The element's in-scope namespace declarations. Makiri tracks no XML
      # namespace declarations, so there are none.
      def namespace_definitions(_node)
        []
      end

      # Makiri's own fragment holding a `<template>` element's contents
      # (Lexbor keeps them off the child list), the same one every time; nil
      # for a node that has none — any node of an XML document, whose contents
      # the template-content registry keeps instead.
      def template_contents(node)
        node.respond_to?(:content_fragment) ? node.content_fragment : nil
      end

      # ----- Namespaced attributes -----
      # Lexbor tracks the attribute's own namespace: set_attribute_ns records
      # it (splitting prefix/local), and the attr node reports
      # namespace_uri/prefix/local_name. So *AttributeNS matches on
      # (namespace, local name) faithfully. `namespace` is an href String or
      # nil throughout.

      def get_attribute_ns(node, namespace, local_name)
        attr_by_ns(node, namespace, local_name)&.value
      end

      def has_attribute_ns?(node, namespace, local_name)
        !attr_by_ns(node, namespace, local_name).nil?
      end

      def set_attribute_ns(node, namespace, prefix, _local_name, qualified_name, value)
        ns = presence(namespace)
        note_namespaced_unprefixed_attribute if prefix.to_s.empty? && !ns.nil?
        name = qualified_name.to_s
        value = value.to_s
        node.set_attribute_ns(ns, name, value) unless ns.nil? && set_null_namespace_attribute(node, name, value)
        value
      end

      # Whether an attribute in a namespace but with no prefix has ever been
      # made (setAttributeNS("urn:x", "id")). That is the only way an
      # attribute whose qualified name is a plain `id` or `class` can be in a
      # namespace — a parser's are either prefixed or, `xmlns` aside, in none —
      # so until one is made, #no_namespace_attribute_value can trust the
      # by-name read. Process-wide, as an attribute moves between documents
      # with its node; it only ever decides how fast an answer comes.
      def note_namespaced_unprefixed_attribute
        @namespaced_unprefixed_attribute = true
      end

      def namespaced_unprefixed_attribute?
        @namespaced_unprefixed_attribute == true
      end

      # Remove by (namespace, local name) — removing by qualified name is
      # ambiguous once same-name/different-namespace attributes coexist.
      def remove_attribute_ns(node, namespace, local_name)
        node.remove_attribute_ns(presence(namespace), local_name.to_s)
        nil
      end

      # Reads a backend attribute node into {namespace_uri:, prefix:,
      # local_name:, qualified_name:, value:} (namespace-aware).
      def attribute_ns_info(attr_node)
        {
          namespace_uri: presence(attr_node.namespace_uri),
          prefix: presence(attr_node.prefix),
          local_name: attr_node.local_name,
          qualified_name: attr_node.name,
          value: attr_node.value,
        }
      end

      # The attribute node whose QUALIFIED name is `qualified_name`, or nil.
      #
      # WHATWG's by-name family ("get an attribute by name", `setAttribute`,
      # `removeAttribute`) matches on the qualified name. A lookup by local
      # name confuses `b` with a prefixed `xml:b`, so those paths must come
      # through here rather than through `node[name]`. Makiri scans natively.
      def attr_by_qualified_name(node, qualified_name)
        node.attribute_by_qualified_name(qualified_name.to_s)
      end

      # That attribute's VALUE, or nil when there is no such attribute. The
      # same match without an attribute node in hand, for the two readers that
      # only ever wanted the value — `getAttribute` and `hasAttribute` — which
      # run on every CSS match and every reflected IDL attribute.
      def attr_value_by_qualified_name(node, qualified_name)
        node.attribute_value_by_qualified_name(qualified_name.to_s)
      end

      # The value of `node`'s attribute named `local_name` in no namespace, or
      # nil — what a selector's `[att]` and HTML's id, class and name read. An
      # attribute in no namespace has its local name as its qualified name, so
      # the native by-name read finds it; only when what it finds is a
      # namespaced, unprefixed one (setAttributeNS("u", "att")) are the
      # attributes listed.
      def no_namespace_attribute_value(node, local_name)
        # The value alone first: no attribute by that name, the common miss,
        # costs one native read and no Attr — and so does a hit, unless an
        # unprefixed namespaced attribute could be the one it read (see
        # #note_namespaced_unprefixed_attribute; a parsed `xmlns` is one).
        value = node.attribute_value_by_qualified_name(local_name)
        return value if value.nil? || (!@namespaced_unprefixed_attribute && local_name != "xmlns")

        attr = attr_by_qualified_name(node, local_name)
        return attr.value if namespace_uri(attr).nil?

        get_attribute_ns(node, nil, local_name)
      end

      # The element's attribute nodes (each readable via attribute_ns_info).
      # The single choke point so DOM code doesn't touch parser internals.
      def attribute_nodes(node)
        node.attribute_nodes
      end

      private

      def with_scope(selector, scope_node)
        return yield(selector) unless scope_node && selector.include?(":scope")

        scope_node[SCOPE_ATTR] = ""
        begin
          yield(selector.gsub(":scope", "[#{SCOPE_ATTR}]"))
        ensure
          scope_node.remove_attribute(SCOPE_ATTR)
        end
      end

      # A null-namespace name that only the DOM's `setAttribute` can make: one
      # whose local name holds a colon ("xlink:href", "v-on:click") or is
      # "xmlns". Makiri checks set_attribute_ns as the DOM's setAttributeNS
      # does, which refuses these (a prefix needs a namespace).
      def set_attribute_only_name?(name)
        name == "xmlns" || name.include?(":")
      end

      # Makiri's own `setAttribute` for the setAttribute-only names, which
      # set_attribute_ns refuses. true when it made the attribute; false
      # leaves every other name to set_attribute_ns, which matches an existing
      # attribute by (namespace, local name) rather than by qualified name:
      # `setAttributeNS("u", "a")` then a null-namespace "a" are two
      # attributes.
      #
      # - An XML document: set_loose_dom_attribute, a plain attribute (never a
      #   namespace declaration) under the name as given.
      # - An HTML document: `[]=`. It lower-cases only on an HTML-namespace
      #   element, as setAttribute does, and makes the colon part of the local
      #   name.
      def set_null_namespace_attribute(node, name, value)
        return false unless set_attribute_only_name?(name)

        if node.respond_to?(:set_loose_dom_attribute)
          node.set_loose_dom_attribute(name, value)
        else
          node[name] = value
        end
        true
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
    end
  end
end
