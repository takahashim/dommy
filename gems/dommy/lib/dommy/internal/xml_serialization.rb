# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG "XML serialization" algorithm (DOM Parsing & Serialization), run over
    # Dommy node wrappers so it is backend-agnostic. Produces namespace-correct
    # XML — default-namespace inheritance/reset, dropping redundant/inconsistent
    # `xmlns`, generating `ns1`/`ns2` prefixes — which a backend's own `to_xml`
    # does not. Namespace declarations are the `xmlns`/`xmlns:*` attributes the
    # spec expects, on the attribute list like any other.
    module XmlSerialization
      XML_NS   = "http://www.w3.org/XML/1998/namespace"
      XMLNS_NS = "http://www.w3.org/2000/xmlns/"
      HTML_NS  = Internal::Namespaces::HTML

      # HTML void elements: when empty and in the HTML namespace they self-close
      # with a trailing space in XML serialization (`<br />`).
      VOID_ELEMENTS = %w[
        area base basefont bgsound br col embed frame hr img input keygen link
        meta param source track wbr
      ].freeze

      # An attribute as the algorithm sees it (regular or a synthesized xmlns).
      Attr = Struct.new(:namespace, :prefix, :local_name, :value)

      # The namespace state the algorithm carries down the tree: the namespace
      # inherited from the parent element, the prefix map, and the counter that
      # mints `ns1`, `ns2`, … The counter is shared across the whole
      # serialization while the map is copied per element, which is why it was a
      # one-element Array standing in for a mutable integer.
      #
      # One object instead of three arguments threaded through four methods,
      # where forgetting to copy the map is a bug that shows up as a mangled
      # prefix several elements later.
      class NamespaceContext
        attr_reader :inherited, :map

        def initialize(inherited, map, counter = [1])
          @inherited = inherited
          @map = map
          @counter = counter
        end

        # Entering an element: it gets its own copy of the map, because the
        # namespaces it declares must not leak to its siblings.
        def enter_element
          self.class.new(@inherited, XmlSerialization.copy_map(@map), @counter)
        end

        # Its children, which inherit the namespace the element resolved and
        # share the map it has already copied.
        def for_children(inherited)
          self.class.new(inherited, @map, @counter)
        end

        # A fresh `nsN` prefix, unique across the serialization.
        def mint_prefix
          prefix = "ns#{@counter[0]}"
          @counter[0] += 1
          prefix
        end
      end

      module_function

      def serialize(node)
        serialize_node(node, root_context)
      end

      # innerHTML in an XML document: the fragment serializing algorithm run on
      # the element, which serializes its children, each from the same fresh
      # state as #serialize (so a top-level child of an XHTML element carries
      # its own xmlns, as browsers write it).
      def serialize_children_of(node)
        serialize_children(node, root_context)
      end

      def root_context
        NamespaceContext.new(nil, { XML_NS => ["xml"] })
      end

      def serialize_node(node, ctx)
        case node_type(node)
        when 1     then serialize_element(node, ctx)
        when 3     then escape_text(string_data(node))
        when 4     then "<![CDATA[#{string_data(node)}]]>"
        when 7     then "<?#{node.target} #{string_data(node)}?>"
        when 8     then "<!--#{string_data(node)}-->"
        when 9, 11 then serialize_children(node, ctx)
        when 10    then serialize_doctype(node)
        else ""
        end
      end

      def serialize_children(node, ctx)
        child_nodes(node).map { |child| serialize_node(child, ctx) }.join
      end

      # https://w3c.github.io/DOM-Parsing/#xml-serializing-an-element-node
      def serialize_element(node, ctx)
        ctx = ctx.enter_element
        local_prefixes = {}
        attrs = element_attributes(node)
        local_default_ns = record_namespace_information(attrs, ctx.map, local_prefixes)
        start = start_tag(node, ctx, local_default_ns, local_prefixes)

        ns = presence(element_namespace(node))
        markup = +"<" << start.markup
        markup << serialize_attributes(attrs, ctx, local_prefixes, start, ns)

        children = child_nodes(node)
        return markup << empty_element_close(ns, node, start.qualified) if children.empty?

        markup << ">"
        child_ctx = ctx.for_children(start.inherited)
        children.each { |child| markup << serialize_node(child, child_ctx) }
        markup << "</#{start.qualified}>"
      end

      # What an element's start tag resolves to, which is four answers at once:
      # the qualified name it is written under (and closed with), the markup up
      # to its attributes — including any xmlns declaration the choice of prefix
      # forced — the namespace its children inherit, and whether its own default
      # xmlns declaration has already been accounted for (`ignore_ns_def`) or
      # even written into that markup (`wrote_default`).
      StartTag = Struct.new(:qualified, :markup, :inherited, :ignore_ns_def, :wrote_default)

      # https://w3c.github.io/DOM-Parsing/#xml-serializing-an-element-node,
      # the prefix-resolution half.
      def start_tag(node, ctx, local_default_ns, local_prefixes)
        map = ctx.map
        ns = presence(element_namespace(node))
        return inherited_namespace_tag(node, ns, ctx.inherited, local_default_ns) if ctx.inherited == ns

        prefix = presence(element_prefix(node))
        candidate = retrieve_preferred_prefix(map, ns, prefix)
        candidate = "xmlns" if prefix == "xmlns"

        if candidate && candidate != "xmlns"
          qualified = "#{candidate}:#{local_name(node)}"
          inherited = ctx.inherited
          if local_default_ns && local_default_ns != XML_NS
            inherited = local_default_ns.empty? ? nil : local_default_ns
          end
          StartTag.new(qualified, qualified, inherited, false, false)
        elsif prefix
          prefix = generate_prefix(map, ns, ctx) if local_prefixes.key?(prefix)
          (map[ns] ||= []) << prefix
          qualified = "#{prefix}:#{local_name(node)}"
          inherited = ctx.inherited
          unless local_default_ns.nil?
            inherited = local_default_ns.empty? ? nil : local_default_ns
          end
          StartTag.new(qualified, qualified + %( xmlns:#{prefix}="#{escape_attr(ns)}"), inherited, false, false)
        elsif local_default_ns.nil? || local_default_ns != ns.to_s
          qualified = local_name(node)
          StartTag.new(qualified, qualified + %( xmlns="#{escape_attr(ns.to_s)}"), ns, true, true)
        else
          qualified = local_name(node)
          StartTag.new(qualified, qualified, ns, false, false)
        end
      end

      # The element is already in the namespace its parent handed down, so it
      # needs no prefix and no declaration — only the `xml:` shorthand, and the
      # note that its own default xmlns declaration is already accounted for.
      def inherited_namespace_tag(node, ns, inherited, local_default_ns)
        qualified = (ns == XML_NS ? "xml:" : "") + local_name(node)
        StartTag.new(qualified, qualified, inherited, !local_default_ns.nil?, false)
      end

      # WHATWG XML serialization of an empty element: an HTML-namespace void
      # element self-closes with a space (`<br />`); any other HTML-namespace
      # element gets an explicit end tag (`<div></div>`); a non-HTML element
      # self-closes (`<foo/>`).
      def empty_element_close(ns, node, qualified)
        return "/>" unless ns == HTML_NS

        VOID_ELEMENTS.include?(local_name(node)) ? " />" : "></#{qualified}>"
      end

      # https://w3c.github.io/DOM-Parsing/#recording-the-namespace
      # Updates `map`/`local_prefixes` from the element's xmlns declarations and
      # returns the default-namespace value declared on the element (or nil).
      def record_namespace_information(attrs, map, local_prefixes)
        default_ns = nil
        attrs.each do |attr|
          if default_ns_declaration?(attr)
            # xmlns="..." — a default namespace declaration.
            default_ns = attr.value
            next
          end
          next unless attr.namespace == XMLNS_NS

          prefix_def = attr.local_name
          ns_def = attr.value
          next if ns_def == XML_NS
          # An already-recorded (prefix → namespace) pairing is redundant.
          next if (map[ns_def] || []).include?(prefix_def)

          (map[ns_def] ||= []) << prefix_def
          local_prefixes[prefix_def] = ns_def
        end
        default_ns
      end

      # Whether `attr` is the element's default-namespace declaration, matched on
      # its LOCAL NAME rather than on its namespace. `setAttribute("xmlns", …)`
      # creates a NULL-namespace attribute — only `setAttributeNS` puts one in
      # the XMLNS namespace, and validate-and-extract lets nothing else be named
      # `xmlns` — yet it is still the declaration the algorithm has to reconcile
      # with the element's real namespace, and drop when the two disagree.
      def default_ns_declaration?(attr)
        attr.prefix.nil? && attr.local_name == "xmlns"
      end

      # https://w3c.github.io/DOM-Parsing/#dfn-retrieve-a-preferred-prefix-string
      def retrieve_preferred_prefix(map, ns, preferred)
        candidates = map[ns.to_s] || map[ns]
        return nil if candidates.nil? || candidates.empty?
        return preferred if preferred && candidates.include?(preferred)

        candidates.last
      end

      # https://w3c.github.io/DOM-Parsing/#dfn-generate-a-prefix
      def generate_prefix(map, ns, ctx)
        generated = ctx.mint_prefix
        (map[ns] ||= []) << generated
        generated
      end

      # https://w3c.github.io/DOM-Parsing/#xml-serializing-the-attributes
      def serialize_attributes(attrs, ctx, local_prefixes, start, element_ns)
        map = ctx.map
        result = +""
        # An element can carry two default declarations (a null-namespace
        # `xmlns` from setAttribute and an XMLNS-namespace one from
        # setAttributeNS), but the start tag holds one `xmlns` at most.
        default_written = start.wrote_default
        attrs.each do |attr|
          # The element start tag has already settled the default namespace —
          # by writing its own `xmlns`, or by taking the one it inherited — so
          # a declaration that contradicts it is dropped. One that agrees with
          # it is kept: the spec drops it too (w3c/DOM-Parsing#47), but
          # Chrome, WebKit and Firefox all write it, and so does WPT's
          # "prefix bound to an empty namespace URI" case
          # (`<root xmlns="" xmlns:foo=""/>`), at the cost of its "redundant
          # xmlns is dropped" case, which every browser fails.
          if default_ns_declaration?(attr)
            next if default_written
            next if start.ignore_ns_def && presence(attr.value) != element_ns

            default_written = true
          end

          ns = presence(attr.namespace)
          prefix = nil

          if ns
            if ns == XMLNS_NS
              # The spec drops an xmlns:foo declaration the start tag already
              # wrote out when it adopted that prefix. We re-emit it instead:
              # redundant, not wrong, and `local_prefixes` alone cannot tell the
              # two apart. Keeping the declaration is the safe half.
              prefix = attr.prefix # "xmlns" for xmlns:foo, nil for xmlns
            elsif ns == XML_NS
              prefix = "xml"
            else
              own = presence(attr.prefix)
              candidate = retrieve_preferred_prefix(map, ns, own)
              if candidate.nil?
                # No prefix in scope maps to the namespace: the attribute keeps
                # its own prefix unless that prefix is already bound in scope
                # (to another namespace, here or on an ancestor) — only then is
                # one generated. So `xl:type` in the XLink namespace stays
                # `xl:type`, while a `p:` an ancestor binds elsewhere becomes
                # `ns1:`. (The spec text only consults the element's own
                # declarations; browsers consult the whole scope, and WPT's
                # ancestor case follows them.)
                if own && !local_prefixes.key?(own) && map.none? { |_ns, prefixes| prefixes.include?(own) }
                  candidate = own
                  (map[ns] ||= []) << candidate
                else
                  candidate = generate_prefix(map, ns, ctx)
                end
                local_prefixes[candidate] = ns
                result << %( xmlns:#{candidate}="#{escape_attr(ns)}")
              end
              prefix = candidate
            end
          end

          result << " "
          result << "#{prefix}:" if prefix
          result << %(#{attr.local_name}="#{escape_attr(attr.value)}")
        end
        result
      end

      # ---- node data access (backend-agnostic, via Dommy wrappers) ----

      def node_type(node)
        return 1  if node.is_a?(Dommy::Element)
        return 4  if defined?(Dommy::CDATASectionNode) && node.is_a?(Dommy::CDATASectionNode)
        return 3  if node.is_a?(Dommy::TextNode)
        return 8  if node.is_a?(Dommy::CommentNode)
        return 7  if node.is_a?(Dommy::ProcessingInstructionNode)
        return 10 if node.is_a?(Dommy::DocumentType)
        return 11 if node.is_a?(Dommy::Fragment)
        return 9  if node.is_a?(Dommy::Document)

        0
      end

      # The element's TRUE namespace from the backend (nil when none) — not the
      # wrapper's #namespace_uri, which defaults to the HTML namespace for HTML
      # documents and isn't right for an XML serialization.
      def element_namespace(node)
        # The backend's raw namespace — the HTML namespace for an HTML element
        # (which an XML serialization DOES declare as xmlns="…xhtml"), or the
        # parsed namespace for an XML element.
        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        presence(backend.respond_to?(:namespace_uri) ? backend.namespace_uri : nil)
      end

      def element_prefix(node)
        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        presence(backend.respond_to?(:prefix) ? backend.prefix : nil)
      end

      # The backend node name is the local part, case-preserved (the wrapper's
      # #local_name lower-cases for HTML).
      def local_name(node)
        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        backend ? backend.local_name : node.__js_get__("nodeName")
      end

      # A <template>'s children, for the XML serialization, are those of its
      # template contents.
      def child_nodes(node)
        node = node.content if node.is_a?(Dommy::HTMLTemplateElement)
        return node.child_nodes.to_a if node.respond_to?(:child_nodes)

        []
      end

      def string_data(node)
        node.respond_to?(:data) ? node.data.to_s : node.__js_get__("data").to_s
      end

      def element_attributes(node)
        node.respond_to?(:attributes) ? node.attributes.to_a.map { |a| attr_struct(a) } : []
      end

      def attr_struct(attr)
        Attr.new(
          presence(attr.respond_to?(:namespace_uri) ? attr.namespace_uri : nil),
          presence(attr.respond_to?(:prefix) ? attr.prefix : nil),
          attr.respond_to?(:local_name) ? attr.local_name : attr.name,
          attr.respond_to?(:value) ? attr.value.to_s : ""
        )
      end

      def serialize_doctype(node)
        name = node.respond_to?(:name) ? node.name : node.__js_get__("name")
        public_id = node.__js_get__("publicId").to_s
        system_id = node.__js_get__("systemId").to_s
        out = +"<!DOCTYPE #{name}"
        if !public_id.empty?
          out << %( PUBLIC "#{public_id}")
          out << %( "#{system_id}") unless system_id.empty?
        elsif !system_id.empty?
          out << %( SYSTEM "#{system_id}")
        end
        out << ">"
      end

      # Each element serializes against its own copy, so its declarations do
      # not leak to its siblings. Public because NamespaceContext#descend is
      # where that copy is taken.
      def copy_map(map)
        map.each_with_object({}) { |(ns, prefixes), out| out[ns] = prefixes.dup }
      end

      def presence(value)
        return nil if value.nil?

        s = value.to_s
        s.empty? ? nil : s
      end

      def escape_text(str)
        str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      def escape_attr(str)
        str.to_s
           .gsub("&", "&amp;")
           .gsub('"', "&quot;")
           .gsub("<", "&lt;")
           .gsub(">", "&gt;")
           .gsub("\t", "&#9;")
           .gsub("\n", "&#10;")
           .gsub("\r", "&#13;")
      end
    end
  end
end
