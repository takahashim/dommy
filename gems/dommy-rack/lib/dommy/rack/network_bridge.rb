# frozen_string_literal: true

require "uri"

module Dommy
  module Rack
    # Routes the document's fetch / XMLHttpRequest polyfills to the session's
    # Rack application. Installed as the window's `__fetch_handler__` — the
    # resolver Dommy's network polyfills consult before their stub maps — so
    # same-origin requests hit the real app (sharing the session's cookie
    # jar), while cross-origin URLs return nil and fall through to whatever
    # stubs the test installed.
    class NetworkBridge
      # Wire a bridge for `session` into `window`. Returns the bridge.
      def self.install(session, window)
        new(session).tap { |bridge| window.globals["__fetch_handler__"] = bridge }
      end

      def initialize(session)
        @session = session
      end

      # The entry-resolver contract (see Dommy::FetchFn): given the request
      # URL and a string-keyed init Hash ("method" / "headers" / "body"),
      # return a stub-shaped entry Hash, or nil to decline.
      def call(url, init = nil)
        init = {} unless init.is_a?(Hash)
        target = absolute_url(url)
        return nil unless target && same_origin?(target)

        response = @session.fetch(
          target,
          method: (init["method"] || "GET").to_s.upcase,
          headers: init["headers"].is_a?(Hash) ? init["headers"] : {},
          body: init["body"]&.to_s
        )
        entry_for(response)
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

      def entry_for(response)
        {
          "status" => response.status,
          "statusText" => ::Rack::Utils::HTTP_STATUS_CODES[response.status].to_s,
          "body" => response.body.to_s,
          "headers" => response.headers,
          "url" => response.url,
          "redirected" => !(response.redirects || []).empty?
        }
      end
    end
  end
end
