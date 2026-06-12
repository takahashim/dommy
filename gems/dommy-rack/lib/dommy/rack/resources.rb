# frozen_string_literal: true

require "uri"

module Dommy
  module Rack
    # `Dommy::Resources` adapter backed by a Rack session: serves same-origin
    # requests from the real app (sharing the session's cookie jar) and declines
    # (returns nil) cross-origin ones so callers fall through to stubs. This is
    # the Rack arm of the single resources interface used for both `<script src>`
    # loads and `fetch` / XHR; `NetworkBridge.install` wires it as the window's
    # fetch handler.
    class Resources
      def initialize(session)
        @session = session
      end

      def get(url, headers: {}) = request(method: "GET", url: url, headers: headers)

      def request(method:, url:, headers: {}, body: nil)
        target = absolute_url(url)
        return nil unless target && same_origin?(target)

        response = @session.fetch(
          target,
          method: method.to_s.upcase,
          headers: headers.is_a?(Hash) ? headers : {},
          body: body&.to_s
        )
        Dommy::Resources::Response.new(
          status: response.status,
          status_text: ::Rack::Utils::HTTP_STATUS_CODES[response.status].to_s,
          headers: response.headers,
          body: response.body.to_s,
          url: response.url,
          redirected: !(response.redirects || []).empty?
        )
      end

      private

      def base_url
        @session.current_url || @session.default_host
      end

      def absolute_url(url)
        URI.join(base_url, url.to_s).to_s
      rescue URI::InvalidURIError
        nil
      end

      def same_origin?(target)
        t = URI.parse(target)
        b = URI.parse(base_url)
        t.scheme == b.scheme && t.host == b.host && t.port == b.port
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
