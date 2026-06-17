# frozen_string_literal: true

require "uri"

module Dommy
  module Rack
    # `Dommy::Resources` adapter backed by a Rack session: serves same-origin
    # requests from the real app (sharing the session's cookie jar). Cross-origin
    # requests are declined (return nil, so callers fall through to stubs) UNLESS
    # the session's subresource allowlist permits the host — letting an embedding
    # browser opt a host in (after prompting) so a SPA's cross-origin bundle can
    # load. Declined cross-origin hosts are recorded on the session for that UI.
    # This is the Rack arm of the single resources interface used for both
    # `<script src>` loads and `fetch` / XHR; `NetworkBridge.install` wires it as
    # the window's fetch handler.
    class Resources
      def initialize(session)
        @session = session
      end

      def get(url, headers: {}) = request(method: "GET", url: url, headers: headers)

      def request(method:, url:, headers: {}, body: nil)
        target = absolute_url(url)
        return nil unless target
        unless same_origin?(target) || allowed_cross_origin?(target)
          record_blocked(target)
          return nil
        end

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

      def allowed_cross_origin?(target)
        host = host_of(target)
        !host.nil? && @session.subresource_host_allowed?(host)
      end

      def record_blocked(target)
        host = host_of(target)
        @session.__internal_record_blocked_subresource(host) if host
      end

      def host_of(target)
        URI.parse(target).host
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
