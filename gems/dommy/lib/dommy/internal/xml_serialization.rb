# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG "XML serialization" algorithm (DOM Parsing & Serialization), run over
    # Dommy node wrappers so it is backend-agnostic. Produces namespace-correct
    # XML — default-namespace inheritance/reset, dropping redundant/inconsistent
    # `xmlns`, generating `ns1`/`ns2` prefixes — which a backend's own `to_xml`
    # does not. Namespace declarations are read via Backend.namespace_definitions
    # (libxml2 models them as namespace nodes, not attributes) and presented to
    # the algorithm as the `xmlns`/`xmlns:*` attributes the spec expects.
    module XmlSerialization
      XML_NS   = "http://www.w3.org/XML/1998/namespace"
      XMLNS_NS = "http://www.w3.org/2000/xmlns/"
      HTML_NS  = "http://www.w3.org/1999/xhtml"

      # An attribute as the algorithm sees it (regular or a synthesized xmlns).
      Attr = Struct.new(:namespace, :prefix, :local_name, :value)

      module_function

      def serialize(node)
        prefix_index = [1]
        serialize_node(node, nil, { XML_NS => ["xml"] }, prefix_index)
      end

      def serialize_node(node, context_ns, map, prefix_index)
        case node_type(node)
        when 1     then serialize_element(node, context_ns, map, prefix_index)
        when 3     then escape_text(string_data(node))
        when 4     then "<![CDATA[#{string_data(node)}]]>"
        when 7     then "<?#{node.target} #{string_data(node)}?>"
        when 8     then "<!--#{string_data(node)}-->"
        when 9, 11 then serialize_children(node, context_ns, map, prefix_index)
        when 10    then serialize_doctype(node)
        else ""
        end
      end

      def serialize_children(node, context_ns, map, prefix_index)
        child_nodes(node).map { |c| serialize_node(c, context_ns, map, prefix_index) }.join
      end

      # https://w3c.github.io/DOM-Parsing/#xml-serializing-an-element-node
      def serialize_element(node, context_ns, map, prefix_index)
        map = copy_map(map)
        local_prefixes = {}
        attrs = element_attributes(node)
        local_default_ns = record_namespace_information(attrs, map, local_prefixes)
        inherited_ns = context_ns
        ns = presence(element_namespace(node))
        ignore_ns_def = false
        markup = +"<"
        qualified = nil

        if inherited_ns == ns
          ignore_ns_def = true unless local_default_ns.nil?
          qualified = (ns == XML_NS ? "xml:" : "") + local_name(node)
          markup << qualified
        else
          prefix = presence(element_prefix(node))
          candidate = retrieve_preferred_prefix(map, ns, prefix)

          if prefix == "xmlns"
            candidate = "xmlns"
          end

          if candidate && candidate != "xmlns"
            qualified = "#{candidate}:#{local_name(node)}"
            if local_default_ns && local_default_ns != XML_NS
              inherited_ns = local_default_ns.empty? ? nil : local_default_ns
            end
            markup << qualified
          elsif prefix
            prefix = generate_prefix(map, ns, prefix_index) if local_prefixes.key?(prefix)
            (map[ns] ||= []) << prefix
            qualified = "#{prefix}:#{local_name(node)}"
            markup << qualified << %( xmlns:#{prefix}="#{escape_attr(ns)}")
            inherited_ns = (local_default_ns.nil? || local_default_ns.empty? ? nil : local_default_ns) unless local_default_ns.nil?
          elsif local_default_ns.nil? || local_default_ns != ns.to_s
            ignore_ns_def = true
            qualified = local_name(node)
            inherited_ns = ns
            markup << qualified << %( xmlns="#{escape_attr(ns.to_s)}")
          else
            qualified = local_name(node)
            inherited_ns = ns
            markup << qualified
          end
        end

        markup << serialize_attributes(attrs, map, prefix_index, local_prefixes, ignore_ns_def)

        children = child_nodes(node)
        if children.empty?
          # HTML void elements get " /", everything else a bare self-close.
          markup << "/>"
          return markup
        end

        markup << ">"
        children.each { |c| markup << serialize_node(c, inherited_ns, map, prefix_index) }
        markup << "</#{qualified}>"
        markup
      end

      # https://w3c.github.io/DOM-Parsing/#recording-the-namespace
      # Updates `map`/`local_prefixes` from the element's xmlns declarations and
      # returns the default-namespace value declared on the element (or nil).
      def record_namespace_information(attrs, map, local_prefixes)
        default_ns = nil
        attrs.each do |attr|
          next unless attr.namespace == XMLNS_NS

          if attr.prefix.nil?
            # xmlns="..." — a default namespace declaration.
            default_ns = attr.value
            next
          end

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

      # https://w3c.github.io/DOM-Parsing/#dfn-retrieve-a-preferred-prefix-string
      def retrieve_preferred_prefix(map, ns, preferred)
        candidates = map[ns.to_s] || map[ns]
        return nil if candidates.nil? || candidates.empty?
        return preferred if preferred && candidates.include?(preferred)

        candidates.last
      end

      # https://w3c.github.io/DOM-Parsing/#dfn-generate-a-prefix
      def generate_prefix(map, ns, prefix_index)
        generated = "ns#{prefix_index[0]}"
        prefix_index[0] += 1
        (map[ns] ||= []) << generated
        generated
      end

      # https://w3c.github.io/DOM-Parsing/#xml-serializing-the-attributes
      def serialize_attributes(attrs, map, prefix_index, local_prefixes, ignore_ns_def)
        result = +""
        attrs.each do |attr|
          ns = presence(attr.namespace)
          prefix = nil

          if ns
            if ns == XMLNS_NS
              # A default-namespace declaration already emitted by the element.
              next if attr.prefix.nil? && ignore_ns_def
              # A prefixed declaration that the element already wrote out.
              next if attr.prefix && local_prefixes[attr.local_name] == attr.value && already_emitted_prefix?(attr)
              prefix = attr.prefix # "xmlns" for xmlns:foo, nil for xmlns
            elsif ns == XML_NS
              prefix = "xml"
            else
              candidate = retrieve_preferred_prefix(map, ns, presence(attr.prefix))
              if candidate.nil?
                candidate = generate_prefix(map, ns, prefix_index)
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

      # An xmlns:foo declaration is re-emitted by serialize_attributes unless the
      # element start tag already wrote it (when it adopted that prefix). We keep
      # it simple: the spec drops a redundant declaration whose (prefix, value) is
      # already in the local prefixes map, which record_namespace_information set.
      def already_emitted_prefix?(_attr)
        false
      end

      # ---- node data access (backend-agnostic, via Dommy wrappers) ----

      def node_type(node)
        return 1  if node.is_a?(Dommy::Element)
        return 4  if defined?(Dommy::CDATASectionNode) && node.is_a?(Dommy::CDATASectionNode)
        return 3  if node.is_a?(Dommy::TextNode)
        return 8  if node.is_a?(Dommy::CommentNode)
        return 7  if node.is_a?(Dommy::ProcessingInstruction)
        return 10 if node.is_a?(Dommy::DocumentType)
        return 11 if node.is_a?(Dommy::Fragment)
        return 9  if node.is_a?(Dommy::Document)

        0
      end

      # The element's TRUE namespace from the backend (nil when none) — not the
      # wrapper's #namespace_uri, which defaults to the HTML namespace for HTML
      # documents and isn't right for an XML serialization.
      def element_namespace(node)
        created = created_namespace(node)
        return presence(created[0]) if created

        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        ns = backend ? Backend.namespace_of(backend) : nil
        presence(ns&.href)
      end

      def element_prefix(node)
        created = created_namespace(node)
        return presence(created[1]) if created

        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        ns = backend ? Backend.namespace_of(backend) : nil
        presence(ns.respond_to?(:prefix) ? ns&.prefix : nil)
      end

      # The backend node name is the local part, case-preserved (the wrapper's
      # #local_name lower-cases for HTML).
      def local_name(node)
        created = created_namespace(node)
        return created[2] if created && presence(created[2])

        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        backend ? backend.name.split(":", 2).last : node.__js_get__("nodeName")
      end

      # The explicit createElementNS [namespace, prefix, local] when the backend
      # (lexbor) didn't retain it, else nil.
      def created_namespace(node)
        node.respond_to?(:__internal_created_namespace__) ? node.__internal_created_namespace__ : nil
      end

      def child_nodes(node)
        return node.child_nodes.to_a if node.respond_to?(:child_nodes)

        []
      end

      def string_data(node)
        node.respond_to?(:data) ? node.data.to_s : node.__js_get__("data").to_s
      end

      # Regular attributes plus xmlns / xmlns:* declarations synthesized from the
      # backend's namespace definitions (which libxml2 keeps off the attribute
      # list). xmlns declarations come first so they populate the prefix map.
      def element_attributes(node)
        ns_attrs = backend_namespace_attrs(node)
        regular = node.respond_to?(:attributes) ? node.attributes.to_a.map { |a| attr_struct(a) } : []
        ns_attrs + regular
      end

      def backend_namespace_attrs(node)
        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
        return [] unless backend

        Backend.namespace_definitions(backend).map do |defn|
          pfx = defn.respond_to?(:prefix) ? defn.prefix : defn.first
          href = defn.respond_to?(:href) ? defn.href : defn.last
          if pfx.nil? || pfx.to_s.empty?
            Attr.new(XMLNS_NS, nil, "xmlns", href.to_s)
          else
            Attr.new(XMLNS_NS, "xmlns", pfx.to_s, href.to_s)
          end
        end
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

      def copy_map(map)
        map.each_with_object({}) { |(k, v), out| out[k] = v.dup }
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
