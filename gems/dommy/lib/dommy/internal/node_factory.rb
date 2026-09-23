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

        # createElement validates against the XML *Name* production, which is
        # looser than the QName an XML backend insists on: ":", "foo:", "f::oo"
        # and a local part with a combining char are all valid element names the
        # backend would reject. The loose creator builds those verbatim; anything
        # it (or the strict path) still refuses is an InvalidCharacterError.
        node =
          begin
            Backend.create_element_loose(local, nil, local, namespace, @document.backend_doc) ||
              Backend.create_element(local, @document.backend_doc)
          rescue ArgumentError
            raise DOMException::InvalidCharacterError, "invalid element name: #{str.inspect}"
          end

        wrapper = @wrappers.wrap(node)
        wrapper.__internal_set_namespace__(namespace, nil, local, local)
        @document.__internal_note_namespaced_element__(namespace, nil)
        wrapper
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
        raise DOMException::InvalidCharacterError, "invalid attribute name: #{str.inspect}" unless str.match?(Namespaces::NAME)

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

      def create_element_ns(namespace_uri, qualified_name)
        # WHATWG "validate and extract": QName-validate the qualifiedName
        # (InvalidCharacterError) and apply the prefix/namespace rules
        # (NamespaceError), then build the element with its prefix bound.
        # namespace is nullable (undefined → null); qualifiedName is a plain
        # DOMString (undefined → "undefined", null → "null").
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name, context: :element)

        # An XML backend rejects some DOM-valid qualified names (an invalid char
        # in the local part, which DOM permits): the loose creator builds them
        # verbatim. A genuinely invalid name it (or the strict path) rejects with
        # an ArgumentError becomes an InvalidCharacterError, per DOM.
        el =
          begin
            Backend.create_element_loose(qualified_name, prefix, local, ns, @document.backend_doc) ||
              Backend.create_element(qualified_name, @document.backend_doc)
          rescue ArgumentError
            raise DOMException::InvalidCharacterError, "'#{qualified_name}' is not a valid element name"
          end
        Backend.add_namespace_definition(el, prefix, ns) if ns

        wrapper = @wrappers.build_element_wrapper(el, namespace: ns, local_name: local)
        wrapper.__internal_set_namespace__(ns, prefix, local, qualified_name)
        @document.__internal_note_namespaced_element__(ns, prefix)
        wrapper
      end

      # Wrap a freshly-cloned backend element whose original was built via
      # createElementNS: route the wrapper class by the known local name (the
      # backend node name may be the full qualified name, e.g. "foo:div", which
      # would otherwise resolve to HTMLUnknownElement) and reapply its namespace
      # metadata (namespaceURI / prefix / localName / tagName).
      def wrap_cloned_element_ns(node, namespace, prefix, local, qualified_name)
        @wrappers.reset_wrapper(node)
        wrapper = @wrappers.build_element_wrapper(node, namespace: namespace, local_name: local)
        wrapper.__internal_set_namespace__(namespace, prefix, local, qualified_name)
        wrapper
      end

      # Query methods

      private

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
