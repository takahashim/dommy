# frozen_string_literal: true

require "cgi/escape"

module Dommy
  module Rails
    # Normalizes URLs so Rails URL-helper output and rendered HTML
    # compare equal despite representational differences.
    #
    # Deliberately lenient: scheme and host are dropped, query
    # parameters are sorted, HTML entities are unescaped, and trailing
    # slashes are removed. Strict external-host matching is out of
    # scope (see README).
    module UrlNormalizer
      module_function

      # What a path-only URL (the common case) is read against: the scheme and
      # host are dropped anyway.
      PLACEHOLDER_BASE = "http://dommy-rails.invalid/"

      def equal?(expected, actual)
        normalize(expected) == normalize(actual)
      end

      def normalize(url)
        url = url.to_s
        return "" if url.empty?

        # Attribute values may arrive HTML-escaped (e.g. &amp; in raw
        # response bodies).
        url = CGI.unescapeHTML(url)

        parsed = Dommy::URL.parse(url, PLACEHOLDER_BASE)
        return url unless parsed

        path = parsed.pathname
        path = path.chomp("/") unless path == "/"

        query = unless parsed.search.empty?
          params = parsed.search_params
          params.sort
          params.to_s
        end

        [path, query].compact.join("?")
      end
    end
  end
end
