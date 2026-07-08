# frozen_string_literal: true

require "uri"

module Dommy
  # `window.location` polyfill. The Window owns one Location and one
  # History instance, and they share the same underlying state. Hash
  # / pushState / replaceState all flow through `__internal_set_url__`.
  class Location
    def initialize(window, origin: "http://localhost", pathname: "/", search: "", hash: "")
      @window = window
      @origin = origin
      @pathname = pathname
      @search = search
      @hash = hash
    end

    def __js_get__(key)
      case key
      when "origin"
        @origin
      when "pathname"
        @pathname
      when "search"
        @search
      when "hash"
        @hash
      when "href"
        href
      when "host"
        # WHATWG host = hostname, plus ":port" only when the port is non-default.
        uri = URI(@origin)
        hostname = uri.host || ""
        port = origin_port_string(uri)
        port.empty? ? hostname : "#{hostname}:#{port}"
      when "hostname"
        URI(@origin).host || ""
      when "protocol"
        URI(@origin).scheme ? "#{URI(@origin).scheme}:" : ""
      when "port"
        origin_port_string(URI(@origin))
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        __internal_navigate_to__(value.to_s, replace: false, source: :location)
      when "hash"
        new_hash = value.to_s
        new_hash = "##{new_hash}" unless new_hash.empty? || new_hash.start_with?("#")
        return if new_hash == @hash

        previous_href = href
        @hash = new_hash
        # Setting the fragment is always same-document — fire hashchange with the
        # full URLs before/after (no delegate navigation).
        @window.fire_hashchange(previous_href, href)
      when "pathname"
        @pathname = value.to_s
      when "search"
        s = value.to_s
        @search = s.empty? || s.start_with?("?") ? s : "?#{s}"
      when "host"
        # `host` is "hostname[:port]" — split and update origin.
        update_origin_host(value.to_s)
      when "hostname"
        update_origin_hostname(value.to_s)
      when "port"
        update_origin_port(value.to_s)
      when "protocol"
        update_origin_protocol(value.to_s)
      end
    end

    include Bridge::Methods
    js_methods %w[assign replace reload toString]
    def __js_call__(method, args)
      case method
      when "assign"
        __internal_navigate_to__(args[0].to_s, replace: false, source: :location)
      when "replace"
        __internal_navigate_to__(args[0].to_s, replace: true, source: :location)
      when "reload"
        # A reload re-requests the current URL (never same-document).
        @window.__internal_navigate__(url: href, method: "GET", replace: true, source: :reload)
      when "toString"
        href
      end
    end

    def href
      "#{@origin}#{@pathname}#{@search}#{@hash}"
    end

    # Internal — accepts an absolute or relative URL string and updates
    # pathname / search / hash. Called by History pushState / replaceState
    # (with `fire_hash: false`, since a pushState never fires hashchange) and by
    # the same-document navigation path. `fire_hash` gates the hashchange event
    # so callers that handle the fragment-change signal themselves can suppress it.
    def __internal_set_url__(raw, fire_hash: true)
      previous_hash = @hash
      previous_href = href
      if raw.start_with?("#")
        @hash = raw
      else
        uri = URI.join(@origin + @pathname + @search + @hash, raw) rescue URI(raw)
        # An absolute URL (carrying scheme + host) navigates to a new
        # origin; a relative URL inherits the current origin from the
        # join base, so rebuilding with the same parts is a no-op.
        rebuild_origin(scheme: uri.scheme, host: uri.host, port: uri.port) if uri.scheme && uri.host
        @pathname = uri.path.to_s == "" ? "/" : uri.path
        @search = uri.query ? "?#{uri.query}" : ""
        @hash = uri.fragment ? "##{uri.fragment}" : ""
      end

      @window.fire_hashchange(previous_href, href) if fire_hash && previous_hash != @hash
    end

    # `location.href = X` / `assign` / `replace`, and the shared entry point for
    # a hyperlink's follow-the-hyperlink. A navigation that changes only the
    # fragment is same-document (always updates the hash + fires hashchange); any
    # other change is cross-document — the intent is handed to the delegate.
    #
    # `sync_cross_doc` controls whether a cross-document target also mutates the
    # URL parts synchronously: true for `location.href=`/assign/replace (a
    # backward-compatible behavior existing code relies on), false for a link
    # click (which leaves the location untouched until the delegate actually
    # navigates — so "nothing happened" is observable with the default
    # NullDelegate). A real delegate rebinds Location on document replacement
    # regardless, so this only affects the no-op default.
    def __internal_navigate_to__(raw, source:, replace: false, sync_cross_doc: true)
      target = resolve(raw)
      if same_document?(href, target)
        __internal_set_url__(raw)
      else
        __internal_set_url__(raw, fire_hash: false) if sync_cross_doc
        @window.__internal_navigate__(url: target, method: "GET", replace: replace, source: source)
      end
    end

    private

    # Resolve a possibly-relative URL against the current full URL.
    def resolve(raw)
      URI.join(href, raw).to_s
    rescue URI::InvalidURIError, ArgumentError
      raw
    end

    # Two URLs address the same document when everything but the fragment matches.
    def same_document?(a, b)
      ua = URI(a)
      ub = URI(b)
      ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port &&
        ua.path == ub.path && ua.query == ub.query
    rescue URI::InvalidURIError, ArgumentError
      false
    end

    def origin_parts
      uri = URI(@origin)
      {scheme: uri.scheme, host: uri.host, port: uri.port}
    rescue URI::InvalidURIError, ArgumentError
      {scheme: "http", host: "localhost", port: 80}
    end

    # WHATWG: the port is the empty string when it equals the scheme's default
    # (URI always fills the default in, so compare against it explicitly).
    def origin_port_string(uri)
      port = uri.port
      return "" if port.nil?

      default = uri.respond_to?(:default_port) ? uri.default_port : nil
      port == default ? "" : port.to_s
    end

    def rebuild_origin(scheme:, host:, port:)
      default_port = (scheme == "https" ? 443 : 80)
      port_segment = (port && port != default_port) ? ":#{port}" : ""
      @origin = "#{scheme}://#{host}#{port_segment}"
    end

    def update_origin_host(value)
      hostname, port = value.split(":", 2)
      parts = origin_parts
      rebuild_origin(scheme: parts[:scheme], host: hostname, port: port&.to_i || parts[:port])
    end

    def update_origin_hostname(value)
      parts = origin_parts
      rebuild_origin(scheme: parts[:scheme], host: value, port: parts[:port])
    end

    def update_origin_port(value)
      parts = origin_parts
      rebuild_origin(scheme: parts[:scheme], host: parts[:host], port: value.to_i)
    end

    def update_origin_protocol(value)
      parts = origin_parts
      scheme = value.to_s.sub(/:\z/, "")
      rebuild_origin(scheme: scheme, host: parts[:host], port: parts[:port])
    end
  end
end
