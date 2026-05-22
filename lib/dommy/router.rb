# frozen_string_literal: true

require "uri"

module Dommy
  # `window.location` polyfill. The Window owns one Location and one
  # History instance, and they share the same underlying state. Hash
  # / pushState / replaceState all flow through `__set_url__`.
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
        __set_url__(value.to_s)
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
        __set_url__(args[0].to_s)
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
    def __set_url__(raw)
      previous_hash = @hash
      if raw.start_with?("#")
        @hash = raw
      else
        uri = URI.join(@origin + @pathname + @search + @hash, raw) rescue URI(raw)
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

  # `window.history` polyfill. Stack-based; back/forward move the
  # cursor. pushState appends; replaceState mutates the current entry.
  # Each entry is `{ state:, url: }`. Popstate fires when back /
  # forward triggers a different cursor (not on pushState per spec).
  class History
    def initialize(window, location)
      @window = window
      @location = location
      # Initial entry mirrors the live Location. Bookmark URL is
      # resynthesized lazily from Location each time we read it.
      @stack = [{state: nil, url: nil}]
      @cursor = 0
      @scroll_restoration = "auto"
    end

    def __js_get__(key)
      case key
      when "length"
        @stack.size
      when "state"
        @stack[@cursor][:state]
      when "scrollRestoration"
        @scroll_restoration
      end
    end

    def __js_set__(key, value)
      case key
      when "scrollRestoration"
        # Per spec, only "auto" and "manual" are accepted. Invalid
        # values silently retain the current value.
        v = value.to_s
        @scroll_restoration = v if %w[auto manual].include?(v)
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "pushState"
        push(args[0], args[2])
      when "replaceState"
        replace(args[0], args[2])
      when "back"
        go(-1)
      when "forward"
        go(1)
      when "go"
        go((args[0] || 0).to_i)
      end
    end

    private

    def push(state, url)
      @stack = @stack[0..@cursor]
      @location.__set_url__(url.to_s) if url
      @stack << {state: state, url: nil}
      @cursor = @stack.size - 1
    end

    def replace(state, url)
      @location.__set_url__(url.to_s) if url
      @stack[@cursor] = {state: state, url: nil}
    end

    def go(delta)
      target = @cursor + delta
      return if target < 0 || target >= @stack.size

      @cursor = target
      @window.fire_popstate(@stack[@cursor][:state])
    end
  end
end
