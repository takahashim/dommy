# frozen_string_literal: true

module Dommy
  module Internal
    # Document's createElement / createTextNode / createAttribute family: mint a
    # backend node, then hand back the wrapper for it.
    #
    # A factory is not a cache. These lived in NodeWrapperCache, which made that
    # class's name describe about a third of it; it keeps the identity table the
    # wrappers come from, and this asks it for them.
    class NodeFactory
      def initialize(document, wrappers)
        @document = document
        @wrappers = wrappers
      end

      def create_element(name, options = nil)
        str = domstring(name)
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid element name: #{str.inspect}" unless Namespaces.valid_element_local_name?(str)

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

        create_an_element(local, namespace, is_option(options)) do
          Backend.create_element(local, namespace, @document.backend_doc)
        end
      end

      # The HTML element constructor run for `new MyElement()` (its
      # definition's construction stack empty): a new element that is custom
      # from the start.
      def create_custom_element(definition)
        node = Backend.create_element(definition.local_name, Element::HTML_NAMESPACE, @document.backend_doc)
        element = @wrappers.wrap(node)
        data = element.__internal_init_ce_data__(definition.autonomous? ? nil : definition.name)
        data.definition = definition
        data.state = "custom"
        element
      end

      def create_text_node(text)
        @wrappers.wrap(Backend.create_text(text.to_s, @document.backend_doc))
      end

      def create_cdata_section(text)
        @wrappers.wrap(Backend.create_cdata(text.to_s, @document.backend_doc))
      end

      def create_comment(text)
        @wrappers.wrap(Backend.create_comment(text.to_s, @document.backend_doc))
      end

      # WHATWG Document.createProcessingInstruction: the target must be a valid
      # XML Name and the data must not contain the PI close delimiter "?>", else
      # InvalidCharacterError. The result is a real backend-backed PI node.
      def create_processing_instruction(target, data)
        t = domstring(target)
        d = domstring(data)
        raise DOMException::InvalidCharacterError, "invalid processing instruction target: #{t.inspect}" unless t.match?(Namespaces::NAME)
        raise DOMException::InvalidCharacterError, "processing instruction data must not contain '?>'" if d.include?("?>")

        @wrappers.wrap(Backend.create_processing_instruction(t, d, @document.backend_doc))
      end

      def create_document_fragment
        @wrappers.wrap(Parser.fragment("", owner_doc: @document.backend_doc))
      end

      def create_attribute(name)
        str = domstring(name)
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid attribute name: #{str.inspect}" unless Namespaces.valid_attribute_local_name?(str)

        # WHATWG createAttribute: an HTML document lower-cases the name (an XML
        # document preserves it). Attr.new no longer folds case, so do it here.
        str = str.downcase if @document.html_document?
        Attr.new(str, document: @document)
      end

      def create_attribute_ns(namespace_uri, qualified_name)
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name)
        Attr.new(qualified_name, namespace_uri: ns, prefix: prefix, local_name: local, document: @document)
      end

      def create_element_ns(namespace_uri, qualified_name, options = nil)
        # WHATWG "validate and extract": QName-validate the qualifiedName
        # (InvalidCharacterError) and apply the prefix/namespace rules
        # (NamespaceError), then build the element with its prefix bound.
        # namespace is nullable (undefined → null); qualifiedName is a plain
        # DOMString (undefined → "undefined", null → "null").
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, = Namespaces.validate_and_extract(namespace_uri, qualified_name, context: :element)

        local = qualified_name.include?(":") ? qualified_name.split(":", 2).last : qualified_name
        create_an_element(local, ns, is_option(options)) do
          Backend.create_element_ns(ns, qualified_name, @document.backend_doc)
        end
      end

      # Query methods

      private

      # DOM "create an element" with the synchronous custom elements flag set
      # (createElement / createElementNS). `make_node` mints the backend node
      # when no autonomous definition constructs the element.
      def create_an_element(local, namespace, is_value)
        definition = CustomElementRegistry.lookup(@document, namespace, local, is_value)
        return create_custom_element_synchronously(definition, local) if definition&.autonomous?

        element = @wrappers.build_element_wrapper(yield)
        return element unless namespace == Element::HTML_NAMESPACE

        data = element.__internal_init_ce_data__(definition ? definition.name : is_value)
        upgrade_synchronously(definition, data) if definition
        element
      end

      # Step 5 (a customized built-in): upgrade the new element now; what that
      # throws is reported, and the element's state is "failed".
      def upgrade_synchronously(definition, data)
        definition.upgrade(data)
      rescue StandardError => e
        definition.report(e)
        data.state = "failed"
      end

      # ElementCreationOptions' `is`, from a dictionary argument (a string
      # argument is the legacy form, which carries none).
      def is_option(options)
        return nil unless options.is_a?(Hash)

        value = options.key?("is") ? options["is"] : options[:is]
        value.nil? || value.equal?(Bridge::UNDEFINED) ? nil : value.to_s
      end

      # DOM "create an element" step 6.2, the synchronous custom elements flag
      # set (createElement / createElementNS): run the definition's
      # constructor now. What it returns must be a new, empty, parentless HTML
      # element of this document with the definition's local name; otherwise
      # — or when it throws — the exception is reported and the element is an
      # HTMLUnknownElement whose custom element state is "failed".
      def create_custom_element_synchronously(definition, local)
        result = definition.construct_synchronously(@document)
        check_constructed_element!(result, local)
        result
      rescue StandardError => e
        definition.report(e)
        node = Backend.create_element(local, Element::HTML_NAMESPACE, @document.backend_doc)
        element = HTMLUnknownElement.new(@document, node)
        @wrappers.register(node, element)
        element.__internal_set_custom_element_state__("failed")
        element
      end

      def check_constructed_element!(result, local)
        unless result.is_a?(HTMLElement) && result.namespace_uri == Element::HTML_NAMESPACE
          raise Bridge::TypeError, "the custom element constructor did not return an HTMLElement"
        end

        problem =
          if result.has_attributes? then "has attributes"
          elsif result.__dommy_backend_node__.children.any? then "has children"
          elsif result.__dommy_backend_node__.parent then "has a parent"
          elsif !result.owner_document.equal?(@document) then "belongs to another document"
          elsif result.local_name != local then "has the local name #{result.local_name.inspect}"
          end
        raise DOMException::NotSupportedError, "the constructed custom element #{problem}" if problem
      end

      # WebIDL DOMString coercion for a name/qualifiedName argument: JS
      # `undefined` → "undefined", JS `null` (Ruby nil) → "null", else #to_s.
      def domstring(value)
        return "undefined" if value.equal?(Bridge::UNDEFINED)
        return "null" if value.nil?

        value.to_s
      end
    end
  end
end
