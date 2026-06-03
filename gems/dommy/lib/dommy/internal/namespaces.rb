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

      # XML Name / QName productions, matching the canonical
      # `xml-name-validator` package (what WHATWG DOM "validate" relies on).
      # Built from the XML 1.0 NameStartChar / NameChar Unicode ranges; an
      # NCName excludes ":", a QName is one optional `prefix:` + local NCName.
      NC_START = "A-Za-z_\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u02FF\\u0370-\\u037D" \
                 "\\u037F-\\u1FFF\\u200C-\\u200D\\u2070-\\u218F\\u2C00-\\u2FEF" \
                 "\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}"
      NC_EXTRA = "\\-.0-9\\u00B7\\u0300-\\u036F\\u203F-\\u2040"
      NCSTART  = "[#{NC_START}]"
      NCCHAR   = "[#{NC_START}#{NC_EXTRA}]"

      # The full Name production (NameStartChar additionally includes ":").
      NAME  = Regexp.new("\\A[:#{NC_START}][:#{NC_START}#{NC_EXTRA}]*\\z")
      # `createElement` / `setAttribute` name validation. Browsers (and the WPT
      # tests that pin web reality) are far more lenient than the XML Name
      # production: any non-empty string with no ASCII whitespace or ">", whose
      # first character is not a digit, ".", "-", "<", ">", or "}". (Names like
      # "f}oo", "f<oo" or a leading combining mark are valid here but not under
      # the strict QName production `createElementNS` still uses.)
      HTML_NAME = /\A(?![\s0-9.\-<>}])[^\s>]+\z/
      # PrefixedName | UnprefixedName.
      QNAME = Regexp.new(
        "(?:\\A#{NCSTART}#{NCCHAR}*:#{NCSTART}#{NCCHAR}*\\z)|(?:\\A#{NCSTART}#{NCCHAR}*\\z)"
      )

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
