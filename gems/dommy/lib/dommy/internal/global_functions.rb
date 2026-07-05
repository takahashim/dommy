# frozen_string_literal: true

require "base64"

require_relative "url_parser"

module Dommy
  module Internal
    # Stateless global functions exposed on the JS global (Window) that don't
    # depend on any window state.
    module GlobalFunctions
      module_function

      # JS `encodeURIComponent`: UTF-8 percent-encode everything except the
      # unreserved marks `A-Za-z0-9 - _ . ! ~ * ' ( )`. (Neither
      # `ERB::Util.url_encode` nor `CGI.escape` matches this set — the former
      # encodes `!~*'()`, the latter uses `+` for space.)
      def encode_uri_component(value)
        value.to_s.b.gsub(/[^A-Za-z0-9\-_.!~*'()]/n) { |c| format("%%%02X", c.ord) }
      end

      # JS `decodeURIComponent`: percent-decode only — unlike form-urlencoded
      # decoding, "+" stays a literal "+". Malformed UTF-8 becomes U+FFFD
      # (a real engine throws URIError; nothing downstream relies on that).
      def decode_uri_component(value)
        UrlParser.percent_decode(value.to_s).force_encoding(Encoding::UTF_8).scrub("\u{FFFD}")
      end

      # JS `btoa`: base64-encode a binary (Latin1) string. Each code unit must be
      # 0..255; anything beyond Latin1 is an InvalidCharacterError (per spec).
      def btoa(value)
        codepoints = value.to_s.codepoints
        if codepoints.any? { |c| c > 0xFF }
          raise DOMException::InvalidCharacterError.new(
            "Failed to execute 'btoa': characters outside the Latin1 range cannot be base64-encoded."
          )
        end

        Base64.strict_encode64(codepoints.pack("C*"))
      end

      # JS `atob`: decode base64 to a binary (Latin1) string. ASCII whitespace is
      # ignored; an invalid alphabet/length is an InvalidCharacterError. The
      # decoded bytes are returned as a string whose code units equal the bytes.
      def atob(value)
        data = value.to_s.gsub(/[\t\n\f\r ]/, "")
        invalid_atob! if data.length % 4 == 1 || !data.match?(%r{\A[A-Za-z0-9+/]*={0,2}\z})

        padded = data + ("=" * ((-data.length) % 4))
        Base64.strict_decode64(padded).bytes.map { |byte| byte.chr(Encoding::UTF_8) }.join
      rescue ArgumentError
        invalid_atob!
      end

      def invalid_atob!
        raise DOMException::InvalidCharacterError.new(
          "Failed to execute 'atob': the string to be decoded is not correctly base64-encoded."
        )
      end
    end
  end
end
