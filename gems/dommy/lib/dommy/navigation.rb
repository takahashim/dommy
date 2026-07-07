# frozen_string_literal: true

module Dommy
  # Navigation host seam. The core fires the *intent* to navigate (a link
  # activation, a `location.assign`, a reload, a cross-document history
  # traversal) at a single point — `Window#__internal_navigate__` — and the
  # attached delegate decides what actually happens. This keeps real page
  # replacement out of the DOM core (it has no network/session model) while
  # letting an embedder (dommy-rack, a core Browser, dommynx) wire it up.
  #
  # Same-document navigation (fragment changes / pushState) never reaches a
  # delegate — the core handles it directly via Location/History and fires
  # hashchange/popstate. Only cross-document navigation is delegated.
  #
  # A delegate is any object responding to:
  #
  #   navigate(url:, method: "GET", body: nil, headers: {}, replace: false, source:)
  #     url:     already-resolved absolute URL string
  #     method:  "GET" | "POST" | ...  (GET for links / location / reload)
  #     body:    request body for a form POST (serialized) or nil
  #     headers: extra request headers (Content-Type, ...)
  #     replace: true to replace the current history entry (location.replace,
  #              a reload, or a redirect)
  #     source:  :link | :form | :location | :reload | :traverse — advisory,
  #              for diagnostics / policy
  #
  #   traverse(delta)
  #     A cross-document history traversal by `delta` entries. With no bfcache
  #     (a Dommy design decision) this re-fetches the target entry's URL, so an
  #     implementation may reduce it to a `navigate`.
  module Navigation
    # The default delegate: it performs no navigation, only *records* each
    # attempt so tests can assert "a navigation to X was triggered" and the
    # observable behaviour is unchanged from before the seam existed.
    class NullDelegate
      attr_reader :attempts

      def initialize
        @attempts = []
      end

      def navigate(url:, source:, method: "GET", body: nil, headers: {}, replace: false)
        @attempts << {
          url: url, method: method, body: body, headers: headers,
          replace: replace, source: source
        }
        nil
      end

      def traverse(delta)
        @attempts << {traverse: delta, source: :traverse}
        nil
      end
    end
  end
end
