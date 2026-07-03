# frozen_string_literal: true

require "uri"

module Dommy
  module Rack
    # IRI → URI normalization. Links and redirect `Location`s on real pages
    # often carry raw, unescaped UTF-8 (e.g. `https://note.com/hashtag/応援`).
    # Ruby's stdlib URI parser is ASCII-only and raises `URI::InvalidURIError`
    # on such a string, which would crash navigation / cookie matching. A
    # browser percent-encodes the non-ASCII bytes (UTF-8) before parsing; this
    # does the same.
    module Url
      module_function

      # Percent-encode the non-ASCII characters in `url` so the ASCII-only URI
      # parser accepts it. Already-encoded `%XX` and every ASCII character
      # (including reserved / sub-delims and `%` itself) are left untouched, so
      # the result is idempotent. The authority (host[:port]) is left alone: a
      # non-ASCII host needs IDNA/Punycode, which is a separate concern — only
      # the path / query / fragment bytes are escaped.
      def encode_iri(url)
        str = url.to_s
        return str if str.ascii_only?

        prefix, rest = split_authority(str)
        prefix + escape_non_ascii(rest)
      end

      # Split `scheme://authority` (left intact) from the path/query/fragment
      # remainder. A string with no `scheme://authority` (a relative ref like
      # `/hashtag/応援`) yields an empty prefix and is escaped whole.
      def split_authority(str)
        if (m = str.match(%r{\A([a-zA-Z][a-zA-Z0-9+.\-]*://[^/?#]*)(.*)\z}m))
          [m[1], m[2]]
        else
          ["", str]
        end
      end

      # Escape every non-ASCII byte as %XX (UTF-8), so a multibyte character
      # becomes its sequence of percent-encoded bytes (応 → %E5%BF%9C).
      def escape_non_ascii(str)
        str.b.gsub(/[^\x00-\x7F]/n) { |byte| format("%%%02X", byte.unpack1("C")) }
      end

      # `host` or `host:port`, omitting a default port (the `Host` header /
      # tuple-origin serialization rule shared by HTTP and WebSocket).
      def http_host(uri)
        uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
      end

      # `scheme://host[:port]`, the tuple origin for `uri` (used for the
      # `Origin` header a same-origin WebSocket connection presents).
      def origin(uri)
        "#{uri.scheme}://#{http_host(uri)}"
      end
    end
  end
end
