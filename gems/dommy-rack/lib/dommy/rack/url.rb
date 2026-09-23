# frozen_string_literal: true

module Dommy
  module Rack
    # Thin helpers around `Dommy::URL` (dommy core's WHATWG URL parser) for the
    # handful of URL operations shared across Session / Navigation / Resources /
    # WebSocketTransport: resolving a possibly-relative URL against a base,
    # same-origin comparison, and building the `SERVER_PORT` a Rack env needs
    # (Dommy::URL#port omits a default port per the URL Standard; a Rack env
    # needs the effective numeric port either way).
    module Url
      module_function

      # scheme => default port, for the tuple-origin schemes dommy-rack ever
      # builds a Rack env for. Mirrors Internal::UrlParser::SPECIAL, which
      # Dommy::URL doesn't expose directly.
      DEFAULT_PORTS = {"http:" => 80, "https:" => 443, "ws:" => 80, "wss:" => 443}.freeze

      # Resolve a possibly-relative `url_or_path` against `base` (both Strings)
      # into an absolute href, or nil on failure. Non-throwing — callers
      # disagree on the right fallback (Navigation keeps the raw input,
      # Resources declines the subresource), so each picks its own via `||`.
      def resolve(base, url_or_path)
        Dommy::URL.parse(url_or_path, base)&.href
      end

      # The effective numeric port for a Dommy::URL (or nil when it isn't a
      # tuple-origin scheme dommy-rack knows how to serve — never expected in
      # practice, since this is only called for URLs already resolved via
      # #resolve or the session's own current/default host).
      def server_port(url)
        return url.port unless url.port.empty?

        DEFAULT_PORTS[url.protocol].to_s
      end

      # Whether two URLs (Strings) share scheme/host/port — the core
      # same-origin check shared by Navigation, Resources, and Session. Deliberately
      # NOT `Dommy::URL#origin` equality: that returns the literal string
      # "null" for any non-tuple-origin scheme (data:, javascript:, …), which
      # would make two unrelated opaque-origin URLs compare as "same origin".
      # Neither side parsing counts as not same-origin, never raises.
      def same_origin?(url_a, url_b)
        a = Dommy::URL.parse(url_a)
        b = Dommy::URL.parse(url_b)
        return false unless a && b

        a.protocol == b.protocol && a.hostname == b.hostname && a.port == b.port
      end
    end
  end
end
