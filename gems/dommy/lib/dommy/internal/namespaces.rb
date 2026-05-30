# frozen_string_literal: true

module Dommy
  module Internal
    # Namespace constants and the WHATWG DOM "validate and extract" algorithm,
    # shared by createAttributeNS / setAttributeNS / createElementNS.
    module Namespaces
      HTML  = "http://www.w3.org/1999/xhtml"
      SVG   = "http://www.w3.org/2000/svg"
      MATHML = "http://www.w3.org/1998/Math/MathML"
      XML   = "http://www.w3.org/XML/1998/namespace"
      XLINK = "http://www.w3.org/1999/xlink"
      XMLNS = "http://www.w3.org/2000/xmlns/"

      # An NCName (Name with no colon); QName is at most one colon joining two.
      NCNAME = /[A-Za-z_][\w.\-]*/.freeze
      QNAME  = /\A(?:#{NCNAME}:)?#{NCNAME}\z/.freeze

      module_function

      # https://dom.spec.whatwg.org/#validate-and-extract
      # Returns [namespace_or_nil, prefix_or_nil, local_name]. Raises
      # DOMException (InvalidCharacterError / NamespaceError) on bad input.
      def validate_and_extract(namespace, qualified_name)
        ns = namespace.to_s
        ns = nil if ns.empty?
        qname = qualified_name.to_s

        unless qname.match?(QNAME)
          raise DOMException::InvalidCharacterError, "invalid qualified name: #{qname.inspect}"
        end

        prefix = nil
        local = qname
        if qname.include?(":")
          prefix, local = qname.split(":", 2)
        end

        if prefix && ns.nil?
          raise DOMException::NamespaceError, "prefix #{prefix.inspect} with null namespace"
        end
        if prefix == "xml" && ns != XML
          raise DOMException::NamespaceError, "prefix 'xml' must use the XML namespace"
        end
        if (qname == "xmlns" || prefix == "xmlns") && ns != XMLNS
          raise DOMException::NamespaceError, "'xmlns' must use the XMLNS namespace"
        end
        if ns == XMLNS && qname != "xmlns" && prefix != "xmlns"
          raise DOMException::NamespaceError, "the XMLNS namespace requires the 'xmlns' name/prefix"
        end

        [ns, prefix, local]
      end
    end
  end
end
