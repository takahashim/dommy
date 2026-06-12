require "uri"

module Dommy
  module Rails
    module UrlNormalizer
      module_function

      def equal?(expected, actual)
        normalize(expected) == normalize(actual)
      end

      def normalize(url)
        return "" if url.nil? || url.empty?

        # Unescape HTML entities before parsing
        url = url.to_s.gsub("&amp;", "&")

        uri = URI.parse(url)
        # Remove scheme and host for comparison
        path = uri.path.to_s
        path = path.chomp("/") unless path == "/"

        # Sort query parameters
        query = if uri.query
          params = URI.decode_www_form(uri.query).sort_by { |k, _| k }
          URI.encode_www_form(params)
        end

        [path, query].compact.join("?")
      rescue URI::InvalidURIError
        url.to_s
      end
    end
  end
end
