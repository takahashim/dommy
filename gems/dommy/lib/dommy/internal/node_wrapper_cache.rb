# frozen_string_literal: true

module Dommy
  module Internal
    # Manages DOM node identity via wrapper caching.
    # Ensures that wrap_node(nokogiri_node) always returns the same Ruby object.
    # Separates identity/caching management from Document's public DOM API.
    class NodeWrapperCache
      def initialize(document)
        @document = document
        @wrappers = {}
      end

      # Returns the wrapped node, creating and caching if needed.
      # Maintains DOM identity across repeated traversals.
      def wrap(node)
        return nil unless node

        cached = @wrappers[identity_key(node)]
        return cached if cached

        wrapper = build_wrapper_for(node)
        @wrappers[identity_key(node)] = wrapper if wrapper
        wrapper
      end

      # Factory methods

      def create_element(name)
        str = domstring(name)
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid element name: #{str.inspect}" unless str.match?(Namespaces::HTML_NAME)

        # WHATWG createElement: lowercase (ASCII) the name only in an HTML
        # document; the namespace is the HTML namespace for HTML/XHTML documents
        # and null for a non-XHTML XML document. Record the metadata so the
        # element's localName/tagName/namespaceURI getters report it faithfully
        # (in particular case preservation for XML/XHTML).
        if @document.html_document?
          local = str.downcase(:ascii)
          namespace = Element::HTML_NAMESPACE
        else
          local = str
          namespace = @document.content_type == "application/xhtml+xml" ? Element::HTML_NAMESPACE : nil
        end

        wrapper = wrap_node(Backend.create_element(local, @document.nokogiri_doc))
        wrapper.__internal_set_namespace__(namespace, nil, local, local)
        wrapper
      end

      def create_text_node(text)
        wrap_node(Backend.create_text(text.to_s, @document.nokogiri_doc))
      end

      def create_cdata_section(text)
        wrap_node(Backend.create_cdata(text.to_s, @document.nokogiri_doc))
      end

      def create_comment(text)
        wrap_node(Backend.create_comment(text.to_s, @document.nokogiri_doc))
      end

      def create_document_fragment
        wrap_node(@document.nokogiri_doc.fragment(""))
      end

      def create_attribute(name)
        str = domstring(name)
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid attribute name: #{str.inspect}" unless str.match?(Namespaces::NAME)

        Attr.new(str)
      end

      def create_attribute_ns(namespace_uri, qualified_name)
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name)
        Attr.new(qualified_name, namespace_uri: ns, prefix: prefix, local_name: local)
      end

      def create_element_ns(namespace_uri, qualified_name)
        # WHATWG "validate and extract": QName-validate the qualifiedName
        # (InvalidCharacterError) and apply the prefix/namespace rules
        # (NamespaceError), then build the element with its prefix bound.
        # namespace is nullable (undefined → null); qualifiedName is a plain
        # DOMString (undefined → "undefined", null → "null").
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name)

        el = Backend.create_element(qualified_name, @document.nokogiri_doc)
        Backend.add_namespace_definition(el, prefix, ns) if ns

        # Route the wrapper class from the requested namespace (the backend may
        # not be able to report it for a detached foreign element).
        wrapper = build_element_wrapper(el, namespace: ns)
        wrapper.__internal_set_namespace__(ns, prefix, local, qualified_name)
        wrapper
      end

      # Query methods

      def query_selector(selector)
        return nil if selector.nil?
        Internal.validate_selector!(selector)
        safe = Internal.backend_safe_selector(selector.to_s)

        if Internal.pseudo_post_filtered?(selector.to_s)
          node = Internal.pseudo_post_filter(Backend.select_all(@document.nokogiri_doc, safe).to_a, selector.to_s, @document).first
          return wrap(node)
        end
        wrap(Backend.select_first(@document.nokogiri_doc, safe))
      end

      def query_selector_all(selector)
        return NodeList.new if selector.nil?
        Internal.validate_selector!(selector)
        safe = Internal.backend_safe_selector(selector.to_s)

        nodes = Backend.select_all(@document.nokogiri_doc, safe).to_a
        nodes = Internal.pseudo_post_filter(nodes, selector.to_s, @document)
        NodeList.new(nodes.map { |node| wrap(node) }.compact)
      end

      def get_element_by_id(id)
        return nil if id.nil? || id.to_s.empty?

        wrap(@document.nokogiri_doc.at_css("##{id}"))
      end

      def get_elements_by_tag_name(name)
        n = name.to_s.downcase
        doc = @document.nokogiri_doc
        cache = self
        if n == "*"
          HTMLCollection.new { doc.css("*").map { |x| cache.wrap(x) }.compact }
        else
          HTMLCollection.new { doc.css(n).map { |x| cache.wrap(x) }.compact }
        end
      end

      def get_elements_by_name(name)
        doc = @document.nokogiri_doc
        cache = self
        key = name.to_s
        HTMLCollection.new do
          doc.css("[name='#{key}']").map { |x| cache.wrap(x) }.compact
        end
      end

      def get_elements_by_class_name(name)
        tokens = name.to_s.split(/\s+/).reject(&:empty?)
        doc = @document.nokogiri_doc
        cache = self
        HTMLCollection.new do
          next [] if tokens.empty?

          selector = tokens.map { |t| ".#{t}" }.join("")
          doc.css(selector).map { |n| cache.wrap(n) }.compact
        end
      end

      # Clear cached wrapper (used by customElements.define for upgrades)
      def reset_wrapper(nokogiri_node)
        @wrappers.delete(identity_key(nokogiri_node))
      end

      # Register an externally-built wrapper. Used by
      # Document#adopt_node when migrating a wrapper from another
      # document so the existing Ruby object survives the move
      # rather than being replaced by a freshly-built one.
      def register(nokogiri_node, wrapper)
        @wrappers[identity_key(nokogiri_node)] = wrapper
      end

      private

      # DOM identity key for a backend node, delegated to the backend since
      # the right key differs: Nokogiri reuses one Ruby wrapper per C node
      # (object_id stable) and may recycle a freed node's pointer, so it keys
      # on object_id; Makiri mints fresh wrappers but never frees nodes, so it
      # keys on the stable node pointer (pointer_id).
      def identity_key(node)
        Backend.identity_key(node)
      end

      # WebIDL DOMString coercion for a name/qualifiedName argument: JS
      # `undefined` → "undefined", JS `null` (Ruby nil) → "null", else #to_s.
      def domstring(value)
        return "undefined" if value.equal?(Bridge::UNDEFINED)
        return "null" if value.nil?

        value.to_s
      end

      def wrap_node(node)
        wrap(node)
      end

      def build_wrapper_for(node)
        case node
        when Backend.element_class
          build_element_wrapper(node)
        when ->(n) { Backend.cdata_class && n.is_a?(Backend.cdata_class) }
          # CDATA is a Text subtype in the backend, so match it before text_class.
          CDATASectionNode.new(@document, node)
        when Backend.text_class
          TextNode.new(@document, node)
        when Backend.comment_class
          CommentNode.new(@document, node)
        when Backend.document_fragment_class
          Fragment.new(@document, node)
        end
      end

      # `namespace` lets a caller that already knows the element's namespace
      # (e.g. createElementNS) route the wrapper class directly, rather than
      # re-deriving it from the backend — which a namespace-less backend can't
      # do for a freshly created, still-detached foreign element.
      def build_element_wrapper(node, namespace: Backend.namespace_of(node)&.href)
        custom_klass = custom_element_class_for(node.name)
        klass = custom_klass || Dommy.element_class_for(node.name, namespace)
        instance = klass.new(@document, node)

        @wrappers[identity_key(node)] = instance

        if custom_klass && instance.respond_to?(:construct)
          begin
            instance.construct
          rescue StandardError
            nil
          end
        end

        instance
      end

      def custom_element_class_for(tag_name)
        # Custom elements are registered on window, not document.
        # Access via default_view if available.
        default_view = @document.default_view
        default_view&.custom_elements&.get(tag_name)
      end
    end
  end
end
