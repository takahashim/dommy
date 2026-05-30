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

        cached = @wrappers[node.object_id]
        return cached if cached

        wrapper = build_wrapper_for(node)
        @wrappers[node.object_id] = wrapper if wrapper
        wrapper
      end

      # Factory methods

      def create_element(name)
        str = name.to_s
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid element name: #{str.inspect}" unless str.match?(Namespaces::NAME)

        wrap_node(Backend.create_element(str.downcase, @document.nokogiri_doc))
      end

      def create_text_node(text)
        wrap_node(Backend.create_text(text.to_s, @document.nokogiri_doc))
      end

      def create_comment(text)
        wrap_node(Backend.create_comment(text.to_s, @document.nokogiri_doc))
      end

      def create_document_fragment
        wrap_node(@document.nokogiri_doc.fragment(""))
      end

      def create_attribute(name)
        str = name.to_s
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid attribute name: #{str.inspect}" unless str.match?(Namespaces::NAME)

        Attr.new(str)
      end

      def create_attribute_ns(namespace_uri, qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name)
        Attr.new(qualified_name.to_s, namespace_uri: ns, prefix: prefix, local_name: local)
      end

      def create_element_ns(namespace_uri, qualified_name)
        # WHATWG "validate and extract": QName-validate the qualifiedName
        # (InvalidCharacterError) and apply the prefix/namespace rules
        # (NamespaceError), then build the element with its prefix bound.
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name)

        el = Backend.create_element(qualified_name.to_s, @document.nokogiri_doc)
        Backend.add_namespace_definition(el, prefix, ns) if ns

        wrapper = wrap(el)
        wrapper.__internal_set_namespace__(ns, prefix, local, qualified_name.to_s)
        wrapper
      end

      # Query methods

      def query_selector(selector)
        return nil if selector.nil? || selector.to_s.empty?

        wrap(@document.nokogiri_doc.at_css(selector.to_s, CSS_PSEUDO_HANDLERS))
      end

      def query_selector_all(selector)
        return NodeList.new if selector.nil? || selector.to_s.empty?

        NodeList.new(@document.nokogiri_doc.css(selector.to_s, CSS_PSEUDO_HANDLERS).map { |node| wrap(node) }.compact)
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
        @wrappers.delete(nokogiri_node.object_id)
      end

      # Register an externally-built wrapper. Used by
      # Document#adopt_node when migrating a wrapper from another
      # document so the existing Ruby object survives the move
      # rather than being replaced by a freshly-built one.
      def register(nokogiri_node, wrapper)
        @wrappers[nokogiri_node.object_id] = wrapper
      end

      private

      def wrap_node(node)
        wrap(node)
      end

      def build_wrapper_for(node)
        case node
        when Backend.element_class
          build_element_wrapper(node)
        when Backend.text_class
          TextNode.new(@document, node)
        when Backend.comment_class
          CommentNode.new(@document, node)
        when Backend.document_fragment_class
          Fragment.new(@document, node)
        end
      end

      def build_element_wrapper(node)
        custom_klass = custom_element_class_for(node.name)
        klass = custom_klass || Dommy.element_class_for(node.name, Backend.namespace_of(node)&.href)
        instance = klass.new(@document, node)

        @wrappers[node.object_id] = instance

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
