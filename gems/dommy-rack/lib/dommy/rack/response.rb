# frozen_string_literal: true

require "json"

module Dommy
  module Rack
    # Wraps a single completed Rack response triple plus the absolute URL it
    # was fetched at. The body is drained eagerly (Rack bodies are one-shot)
    # and the Dommy document is parsed lazily on first access.
    class Response
      HTML_CONTENT_TYPES = ["text/html", "application/xhtml+xml"].freeze
      REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

      attr_reader :status, :headers, :url

      # The redirects followed to reach this response, oldest first. Each entry
      # is {status:, url:, location:}. Empty unless this was the final response
      # of a followed redirect chain. Set by Navigation.
      attr_accessor :redirects

      def initialize(status, headers, body, url:)
        @status = status.to_i
        @headers = headers || {}
        @url = url
        @body = drain_body(body)
        @document_parsed = false
        @window = nil
        @redirects = []
      end

      def body
        @body
      end

      # Content-Type with any parameters (charset, boundary) stripped.
      def content_type
        raw = header("content-type")
        return nil unless raw

        raw.split(";", 2).first.to_s.strip.downcase
      end

      def html?
        HTML_CONTENT_TYPES.include?(content_type)
      end

      # True when the response advertises a JSON content type, including
      # structured-suffix types such as application/vnd.api+json.
      def json?
        ct = content_type
        return false unless ct

        ct == "application/json" || ct == "text/json" || ct.end_with?("+json")
      end

      # The parsed JSON body. Parses regardless of Content-Type so that
      # servers mislabeling JSON still work; raises JSON::ParserError on
      # invalid JSON. Pass symbolize_names: true for symbol keys.
      def json(symbolize_names: false)
        JSON.parse(@body, symbolize_names: symbolize_names)
      end

      def redirect?
        REDIRECT_STATUSES.include?(@status)
      end

      # --- Status-class predicates ---

      def success? = (200..299).cover?(@status)
      def client_error? = (400..499).cover?(@status)
      def server_error? = (500..599).cover?(@status)
      def error? = @status >= 400
      def not_found? = @status == 404

      def location_header
        header("location")
      end

      # The redirect target of an immediate (delay 0) <meta http-equiv=
      # "refresh">, or nil. The HTML analog of location_header. A self-refresh
      # with no URL is ignored to avoid reload loops; non-HTML responses and
      # non-zero delays return nil.
      def meta_refresh_url
        return nil unless html?

        meta = document&.query_selector_all("meta")
          &.find { |m| m.get_attribute("http-equiv")&.downcase == "refresh" }
        return nil unless meta

        delay, _, rest = meta.get_attribute("content").to_s.partition(";")
        return nil unless delay.strip.match?(/\A0+\z/)

        url = rest.strip.sub(/\Aurl\s*=\s*/i, "").delete("\"'").strip
        url.empty? ? nil : url
      end

      # All Set-Cookie values, handling both single-string (newline-joined)
      # and array header shapes across Rack 2 and Rack 3.
      def set_cookie_strings
        values = lookup_header("set-cookie")
        Array(values).flat_map { |v| v.to_s.split("\n") }.reject(&:empty?)
      end

      # The parsed Dommy window, or nil for non-HTML responses.
      def window
        parse_document! unless @document_parsed
        @window
      end

      def document
        window&.document
      end

      private

      def drain_body(body)
        return +"" if body.nil?
        return body.dup if body.is_a?(String)

        parts = []
        body.each { |part| parts << part }
        parts.join
      ensure
        body.close if body.respond_to?(:close)
      end

      def parse_document!
        @document_parsed = true
        return unless html?

        @window = Dommy.parse(@body)
        # Location#href= updates origin too (Dommy resolves absolute URLs),
        # so a single assignment configures the full document URL.
        @window.location.__js_set__("href", @url) if @url
        @window.document.content_type = content_type if content_type
      end

      # Case-insensitive single-value header lookup.
      def header(name)
        value = lookup_header(name)
        value.is_a?(Array) ? value.first : value
      end

      def lookup_header(name)
        target = name.downcase
        @headers.each do |key, value|
          return value if key.to_s.downcase == target
        end
        nil
      end
    end
  end
end
