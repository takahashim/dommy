# frozen_string_literal: true

require "base64"

module Dommy
  # Decode an RFC 2397 `data:` URI into its bytes + media type, so `fetch` / XHR
  # to an inline `data:` URL resolves like a browser (200 + the decoded payload)
  # instead of falling through to a 404. note.com loads its icon SVGs as
  # `data:image/svg+xml;base64,…` via XHR, which hit this.
  module DataUri
    module_function

    # `{ body:, content_type: }` for a `data:` URL, or nil for any other URL.
    # The payload is returned as UTF-8 text (the common case for the `text/*` and
    # `image/svg+xml` data URLs fetched this way).
    def parse(url)
      str = url.to_s
      return nil unless str.start_with?("data:")

      meta, data = str[5..].split(",", 2)
      return nil if data.nil?

      base64 = meta.end_with?(";base64")
      media = meta.sub(/;base64\z/, "")
      media = "text/plain;charset=US-ASCII" if media.empty?
      bytes =
        if base64
          Base64.decode64(data)
        else
          data.gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }
        end
      {body: bytes.dup.force_encoding(Encoding::UTF_8), content_type: media}
    end
  end
end
