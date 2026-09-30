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

      # The XML 1.0 Name production, matching the canonical
      # `xml-name-validator` package, built from the NameStartChar / NameChar
      # Unicode ranges.
      NC_START = "A-Za-z_\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D" \
                 "\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF" \
                 "\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}"
      NC_EXTRA = "\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040"

      # The full Name production (NameStartChar additionally includes ":").
      # Still the rule for a processing instruction's target.
      NAME  = Regexp.new("\\A[:#{NC_START}][:#{NC_START}#{NC_EXTRA}]*\\z")

      # The DOM's own name rules (https://dom.spec.whatwg.org/#namespaces),
      # which replaced the XML Name / QName productions: far looser, and what
      # browsers implement (WPT dom/nodes/name-validation.html).
      #
      # Code points forbidden anywhere in a "valid namespace prefix", and after
      # an ASCII alpha in a "valid element local name": ASCII whitespace (TAB,
      # LF, FF, CR, SPACE), NULL, U+002F (/), U+003E (>).
      LOCAL_FORBIDDEN = Regexp.new("[\\u0000\\u0009\\u000A\\u000C\\u000D\\u0020/>]")
      # The same set plus U+003D (=), forbidden in a "valid attribute local
      # name".
      ATTRIBUTE_LOCAL_FORBIDDEN = Regexp.new("[\\u0000\\u0009\\u000A\\u000C\\u000D\\u0020/=>]")
      # A "valid element local name": an ASCII alpha followed by anything but
      # LOCAL_FORBIDDEN, or ":", "_" or a code point U+0080 and above followed
      # only by ASCII alphanumerics, "-", ".", ":", "_" and code points U+0080
      # and above. (The spec gives this regular expression itself.)
      ELEMENT_LOCAL_NAME = Regexp.new(
        "\\A(?:[A-Za-z][^\\u0000\\u0009\\u000A\\u000C\\u000D\\u0020/>]*" \
        "|[:_\\u0080-\\u{10FFFF}][A-Za-z0-9\\-.:_\\u0080-\\u{10FFFF}]*)\\z"
      )
      # Forbidden in a "valid doctype name" (which may be empty): ASCII
      # whitespace, NULL, U+003E (>).
      DOCTYPE_FORBIDDEN = Regexp.new("[\\u0000\\u0009\\u000A\\u000C\\u000D\\u0020>]")

      module_function

      def valid_namespace_prefix?(str)
        !str.empty? && !str.match?(LOCAL_FORBIDDEN)
      end

      def valid_attribute_local_name?(str)
        !str.empty? && !str.match?(ATTRIBUTE_LOCAL_FORBIDDEN)
      end

      def valid_element_local_name?(str)
        str.match?(ELEMENT_LOCAL_NAME)
      end

      def valid_doctype_name?(str)
        !str.match?(DOCTYPE_FORBIDDEN)
      end

      # https://dom.spec.whatwg.org/#validate-and-extract
      # Returns [namespace_or_nil, prefix_or_nil, local_name]. Raises
      # DOMException (InvalidCharacterError / NamespaceError) on bad input.
      #
      # The prefix must be a valid namespace prefix, and the local name a valid
      # element local name (`context: :element` — createElementNS,
      # createDocument) or a valid attribute local name (`context: :attribute`,
      # the default — createAttributeNS, setAttributeNS).
      def validate_and_extract(namespace, qualified_name, context: :attribute)
        ns = namespace.to_s
        ns = nil if ns.empty?
        qname = qualified_name.to_s

        prefix = nil
        local = qname
        if qname.include?(":")
          # Split on the FIRST colon: any further colons stay in the local part
          # (e.g. "f:o:o" → prefix "f", local "o:o").
          prefix, local = qname.split(":", 2)
        end

        if prefix && !valid_namespace_prefix?(prefix)
          raise DOMException::InvalidCharacterError, "invalid namespace prefix: #{prefix.inspect}"
        end
        valid_local = context == :element ? valid_element_local_name?(local) : valid_attribute_local_name?(local)
        raise DOMException::InvalidCharacterError, "invalid local name: #{local.inspect}" unless valid_local

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
