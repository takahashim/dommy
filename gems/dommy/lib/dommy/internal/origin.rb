# frozen_string_literal: true

require_relative "url_parser"

module Dommy
  module Internal
    # Origins of documents and URLs, serialized (HTML "origin" / URL "origin"),
    # and the Secure Contexts trustworthiness checks built on them.
    module Origin
      module_function

      # The serialized origin of a URL string: a scheme/host/port tuple for the
      # special schemes, the inner URL's origin for blob:, "null" (opaque) for
      # everything else and for a URL that does not parse.
      def of_url(url)
        Dommy::URL.new(url.to_s).origin
      rescue StandardError
        "null"
      end

      # The serialized origin of a Window's associated Document. A document whose
      # URL matches about:blank or is about:srcdoc gets its origin from the
      # document that created it — for a nested one, its container's document —
      # rather than the opaque origin of its URL.
      def of_window(window)
        seen = []
        while window && !seen.include?(window)
          seen << window
          return "null" if window.respond_to?(:__internal_opaque_origin__) && window.__internal_opaque_origin__
          url = window.location&.href.to_s
          return of_url(url) unless inherits_origin?(url)

          window = creator_of(window)
        end
        "null"
      end

      def inherits_origin?(url)
        record = UrlParser.parse(url)
        record.scheme == "about" && %w[blank srcdoc].include?(UrlParser.serialize_path(record))
      rescue UrlParser::Failure
        false
      end

      # The window whose document created `window`'s document: the container's
      # document's window for a nested browsing context.
      def creator_of(window)
        frame = window.frame_element
        frame&.owner_document&.default_view
      end

      # Secure Contexts "Is url potentially trustworthy?".
      def potentially_trustworthy_url?(url)
        record = UrlParser.parse(url.to_s)
        return true if record.scheme == "about" && %w[blank srcdoc].include?(UrlParser.serialize_path(record))
        return true if record.scheme == "data"

        trustworthy_record?(record)
      rescue UrlParser::Failure
        false
      end

      # "Is origin potentially trustworthy?" for the origin of a parsed URL.
      def trustworthy_record?(record)
        return true if %w[https wss file].include?(record.scheme)
        return false unless %w[http ws].include?(record.scheme)

        host = record.host.to_s
        host == "[::1]" || host.match?(/\A127\.\d+\.\d+\.\d+\z/) ||
          host == "localhost" || host.end_with?(".localhost")
      end

      # The host of a serialized tuple origin, or nil for an opaque one.
      def host_of(serialized)
        return nil if serialized.nil? || serialized == "null" || serialized.empty?

        UrlParser.parse(serialized).host
      rescue UrlParser::Failure
        nil
      end
    end
  end
end
