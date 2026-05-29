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
        URI(@origin).host || ""
      when "hostname"
        URI(@origin).host || ""
      when "protocol"
        URI(@origin).scheme ? "#{URI(@origin).scheme}:" : ""
      when "port"
        (URI(@origin).port || 80).to_s
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        __internal_set_url__(value.to_s)
      when "hash"
        new_hash = value.to_s
        new_hash = "##{new_hash}" unless new_hash.empty? || new_hash.start_with?("#")
        previous = @hash
        @hash = new_hash
        @window.fire_hashchange(previous, @hash) if previous != @hash
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

    def __js_call__(method, args)
      case method
      when "assign", "replace"
        __internal_set_url__(args[0].to_s)
      when "reload"
        nil
      when "toString"
        href
      end
    end

    def href
      "#{@origin}#{@pathname}#{@search}#{@hash}"
    end

    # Internal — accepts an absolute or relative URL string and
    # updates pathname / search / hash. Called by History pushState /
    # replaceState and by `location.href = ...`.
    def __internal_set_url__(raw)
      previous_hash = @hash
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

      @window.fire_hashchange(previous_hash, @hash) if previous_hash != @hash
    end

    private

    def origin_parts
      uri = URI(@origin)
      {scheme: uri.scheme, host: uri.host, port: uri.port}
    rescue URI::InvalidURIError, ArgumentError
      {scheme: "http", host: "localhost", port: 80}
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
