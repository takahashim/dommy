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
        target = served_target(method: method, url: url, headers: headers, body: body)
        return nil unless target

        to_resources_response(@session.fetch(
          target,
          method: method.to_s.upcase,
          headers: headers.is_a?(Hash) ? headers : {},
          body: body&.to_s
        ))
      end

      # The async-network counterpart of #request: makes the same page-thread
      # serve/decline decision (origin gate, blocked-host recording), then — for a
      # served URL — returns a worker-safe thunk that runs the request off the
      # page thread and yields a Resources::Response. Returns nil for a URL we do
      # not serve, exactly like #request, so the fetch handler falls through to
      # stubs. The fetch handler submits the thunk to the network executor.
      def request_job(method:, url:, headers: {}, body: nil)
        target = served_target(method: method, url: url, headers: headers, body: body)
        return nil unless target

        job = @session.build_subresource_fetch_job(
          target,
          method: method.to_s.upcase,
          headers: headers.is_a?(Hash) ? headers : {},
          body: body&.to_s
        )
        -> { to_resources_response(job.call) }
      end

      private

      # Resolve `url` to an absolute target we serve (same-origin, or a host the
      # session has allowed), recording and declining (nil) a cross-origin host.
      # Shared by the sync #request and the async #request_job so both make the
      # identical serve/decline decision on the page thread.
      def served_target(method:, url:, headers:, body:)
        target = absolute_url(url)
        return nil unless target
        return target if same_origin?(target) || allowed_cross_origin?(target)

        record_blocked(target)
        nil
      end

      def to_resources_response(response)
        Dommy::Resources::Response.new(
          status: response.status,
          status_text: ::Rack::Utils::HTTP_STATUS_CODES[response.status].to_s,
          headers: response.headers,
          body: response.body.to_s,
          url: response.url,
          redirected: !(response.redirects || []).empty?
        )
      end

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
