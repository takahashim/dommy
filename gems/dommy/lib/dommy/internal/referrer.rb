# frozen_string_literal: true

require_relative "origin"

module Dommy
  module Internal
    # The Referer a page's script request (fetch(), XMLHttpRequest) carries:
    # Fetch's "determine request's referrer" under the Referrer Policy
    # algorithms, with the document's policy from `<meta name="referrer">`.
    module Referrer
      POLICIES = %w[
        no-referrer no-referrer-when-downgrade same-origin origin strict-origin
        origin-when-cross-origin strict-origin-when-cross-origin unsafe-url
      ].freeze

      DEFAULT_POLICY = "strict-origin-when-cross-origin"

      # The legacy `<meta name="referrer">` keywords HTML maps to a policy.
      LEGACY_META_POLICIES = {
        "never" => "no-referrer",
        "default" => "strict-origin-when-cross-origin",
        "always" => "unsafe-url",
        "origin-when-crossorigin" => "origin-when-cross-origin"
      }.freeze

      # A full referrer longer than this is sent as its origin.
      MAX_LENGTH = 4096

      # A request's referrer when it is the page that made it (Fetch's
      # "client"), as Request#referrer serializes it.
      CLIENT = "about:client"

      LOCAL_SCHEMES = %w[about blob data].freeze

      class << self
        # A RequestInit's `referrer` as the request's referrer: "" for none,
        # CLIENT for the page, or a URL of the page's origin (one of another
        # origin, or `about:client`, is the page). Raises TypeError for a URL
        # that does not parse.
        def request_referrer(window, value)
          return CLIENT if value.nil? || value.equal?(Bridge::UNDEFINED)

          value = value.to_s
          return "" if value.empty?
          return CLIENT if window.nil?

          parsed = window.__internal_parse_url__(value, utf8: true)
          raise Bridge::TypeError, "Failed to construct 'Request': Referrer '#{value}' is not a valid URL." if parsed.nil?
          return CLIENT if parsed == CLIENT || Origin.of_url(parsed) != Origin.of_window(window)

          parsed
        end

        # A RequestInit's `referrerPolicy`: "" (the document's) or one of
        # POLICIES; anything else is not a ReferrerPolicy value (TypeError).
        def request_policy(value)
          return "" if value.nil? || value.equal?(Bridge::UNDEFINED)

          value = value.to_s
          return value if value.empty? || POLICIES.include?(value)

          raise Bridge::TypeError, "Failed to construct 'Request': '#{value}' is not a valid referrer policy."
        end

        # The Referer header for a request to `url` made by `window`'s document
        # with the request's `referrer` and `policy` (see above), or nil to send
        # none.
        def header_value(window, url, referrer: CLIENT, policy: "")
          return nil if referrer.empty?

          source = referrer == CLIENT ? client_url(window) : referrer
          return nil if source.nil?

          policy = document_policy(window.document) if policy.empty?
          apply(policy, source, url.to_s)
        end

        private

        # The URL a request the page makes is from: its document's, or for an
        # iframe srcdoc document its container's; none for an opaque origin.
        def client_url(window)
          return nil if Origin.of_window(window) == "null"

          seen = []
          until window.nil? || seen.include?(window)
            seen << window
            url = window.location&.href.to_s
            return url unless url == "about:srcdoc"

            window = Origin.creator_of(window)
          end
          nil
        end

        # The document's referrer policy: the last `<meta name="referrer">` with
        # a policy for content, else the default.
        def document_policy(document)
          return DEFAULT_POLICY if document.nil?

          document.query_selector_all("meta[name]").reverse_each do |meta|
            next unless meta.get_attribute("name").to_s.casecmp?("referrer")

            content = meta.get_attribute("content").to_s.strip.downcase(:ascii)
            content = LEGACY_META_POLICIES.fetch(content, content)
            return content if POLICIES.include?(content)
          end
          DEFAULT_POLICY
        end

        # Referrer Policy "determine request's referrer" for a request from
        # `source` to `target`.
        def apply(policy, source, target)
          full = strip(source)
          return nil if full.nil?

          origin = strip(source, origin_only: true)
          full = origin if full.length > MAX_LENGTH
          same_origin = Origin.of_url(source) == Origin.of_url(target)
          downgrade = Origin.potentially_trustworthy_url?(source) && !Origin.potentially_trustworthy_url?(target)

          case policy
          when "no-referrer" then nil
          when "origin" then origin
          when "unsafe-url" then full
          when "strict-origin" then downgrade ? nil : origin
          when "same-origin" then same_origin ? full : nil
          when "origin-when-cross-origin" then same_origin ? full : origin
          when "no-referrer-when-downgrade" then downgrade ? nil : full
          else same_origin ? full : (downgrade ? nil : origin)
          end
        end

        # "Strip url for use as a referrer": no credentials or fragment, and
        # with `origin_only` no path or query; nil for a local scheme.
        def strip(url, origin_only: false)
          parsed = Dommy::URL.new(url)
          return nil if LOCAL_SCHEMES.include?(parsed.protocol.delete_suffix(":"))
          return "#{parsed.origin}/" if origin_only

          parsed.username = ""
          parsed.password = ""
          parsed.hash = ""
          parsed.href
        rescue StandardError
          nil
        end
      end
    end
  end
end
