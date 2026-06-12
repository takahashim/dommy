# frozen_string_literal: true

require "cgi"
require "uri"

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

      def equal?(expected, actual)
        normalize(expected) == normalize(actual)
      end

      def normalize(url)
        url = url.to_s
        return "" if url.empty?

        # Attribute values may arrive HTML-escaped (e.g. &amp; in raw
        # response bodies).
        url = CGI.unescapeHTML(url)

        uri = URI.parse(url)
        path = uri.path.to_s
        path = path.chomp("/") unless path == "/"

        query = if uri.query
          params = URI.decode_www_form(uri.query).sort_by { |k, _| k }
          URI.encode_www_form(params)
        end

        [path, query].compact.join("?")
      rescue URI::InvalidURIError
        url
      end
    end
  end
end
