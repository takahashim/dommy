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
      # the strict QName production the *AttributeNS family still uses.)
      HTML_NAME = /\A(?![\s0-9.\-<>}])[^\s>]+\z/
      # PrefixedName | UnprefixedName.
      QNAME = Regexp.new(
        "(?:\\A#{NCSTART}#{NCCHAR}*:#{NCSTART}#{NCCHAR}*\\z)|(?:\\A#{NCSTART}#{NCCHAR}*\\z)"
      )

      # Code points forbidden anywhere in a "valid local name" / "valid namespace
      # prefix" per the modern WHATWG algorithm: ASCII whitespace (TAB, LF, FF,
      # CR, SPACE), NULL, U+002F (/), U+003E (>).
      LOCAL_FORBIDDEN = Regexp.new("[\\u0000\\u0009\\u000A\\u000C\\u000D\\u0020/>]")
      # Valid first code point of an element local name: ASCII alpha, U+003A (:),
      # U+005F (_), or any code point U+0080 and above.
      ELEMENT_LOCAL_START = Regexp.new("\\A[A-Za-z:_\\u0080-\\u{10FFFF}]")

      module_function

      def valid_namespace_prefix?(str)
        !str.empty? && !str.match?(LOCAL_FORBIDDEN)
      end

      def valid_element_local_name?(str)
        return false if str.empty?
        return false unless str.match?(ELEMENT_LOCAL_START)

        rest = str[1..]
        rest.nil? || rest.empty? || !rest.match?(LOCAL_FORBIDDEN)
      end

      # https://dom.spec.whatwg.org/#validate-and-extract
      # Returns [namespace_or_nil, prefix_or_nil, local_name]. Raises
      # DOMException (InvalidCharacterError / NamespaceError) on bad input.
      #
      # `context: :element` applies the modern WHATWG "validate" character rules
      # (lenient: a restricted first code point then any non-forbidden code
      # points, multiple colons allowed when namespaced). `context: :attribute`
      # (the default) keeps the strict XML QName production used historically by
      # the *AttributeNS family.
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

        if context == :element
          if prefix && !valid_namespace_prefix?(prefix)
            raise DOMException::InvalidCharacterError, "invalid namespace prefix: #{prefix.inspect}"
          end
          unless valid_element_local_name?(local)
            raise DOMException::InvalidCharacterError, "invalid local name: #{local.inspect}"
          end
        else
          unless qname.match?(QNAME)
            raise DOMException::InvalidCharacterError, "invalid qualified name: #{qname.inspect}"
          end
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
