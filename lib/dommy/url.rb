# frozen_string_literal: true

require "uri"
require "cgi"

module Dommy
  # `URL` — WHATWG-style URL parsing. Public API mirrors the JS class:
  #
  #   u = Dommy::URL.new("https://x.test/a/b?k=v#h")
  #   u.protocol  # "https:"
  #   u.host      # "x.test"
  #   u.pathname  # "/a/b"
  #   u.search    # "?k=v"
  #   u.hash      # "#h"
  #   u.search_params.get("k")  # "v"
  #
  # Construction with a base URL is supported for relative inputs:
  #   Dommy::URL.new("/a", "https://x.test").href
  #     # => "https://x.test/a"
  #
  # Internally backed by Ruby's URI library — good enough for the
  # common test cases. Edge cases that URI rejects raise
  # `DOMException::SyntaxError` (called `TypeError` in JS but Dommy
  # uses the closest WHATWG name).
  class URL
    # Registry of Blob URLs created via `URL.createObjectURL(blob)`.
    # Process-wide because the spec scopes them to the document/window
    # lifecycle, but Dommy is a single-process test harness.
    @blob_urls = {}

    class << self
      # Create a unique blob: URL that resolves back to `blob` via
      # `URL.__resolve_blob_url__(url)`. Returns nil for non-Blob input.
      def create_object_url(blob)
        return nil unless blob.is_a?(Blob)

        id = "%032x" % rand(2 ** 128)
        url = "blob:dommy/#{id}"
        @blob_urls[url] = blob
        url
      end

      alias createObjectURL create_object_url

      # Revoke a previously-created blob URL. No-op for unknown URLs,
      # matching the spec.
      def revoke_object_url(url)
        @blob_urls.delete(url.to_s)
        nil
      end

      alias revokeObjectURL revoke_object_url

      # Resolve a blob: URL back to its Blob, or nil if revoked / unknown.
      # Internal — used by fetch / XHR implementations that load blob URLs.
      def __resolve_blob_url__(url)
        @blob_urls[url.to_s]
      end

      # Test seam: drop all registered blob URLs.
      def __reset_blob_urls__
        @blob_urls.clear
      end
    end

    attr_reader :search_params

    def initialize(input, base = nil)
      raw = parse_with_base(input, base)
      @uri = raw
      @search_params = URLSearchParams.new(raw.query.to_s, owner: self)
    end

    def href
      build_href
    end

    def href=(value)
      raw = parse_with_base(value.to_s, nil)
      @uri = raw
      @search_params.__replace__(raw.query.to_s)
      build_href
    end

    def protocol
      @uri.scheme ? "#{@uri.scheme}:" : ""
    end

    def protocol=(value)
      s = value.to_s.sub(/:$/, "")
      @uri.scheme = s
    end

    def host
      port = @uri.port
      default = @uri.default_port
      hostpart = @uri.host.to_s
      return hostpart if port.nil? || port == default

      "#{hostpart}:#{port}"
    end

    def host=(value)
      h, p = value.to_s.split(":", 2)
      @uri.host = h
      @uri.port = p.to_i if p
    end

    def hostname
      @uri.host.to_s
    end

    def hostname=(value)
      @uri.host = value.to_s
    end

    def port
      return "" if @uri.port.nil? || @uri.port == @uri.default_port

      @uri.port.to_s
    end

    def port=(value)
      @uri.port = value.to_s.empty? ? nil : value.to_i
    end

    def pathname
      @uri.path.to_s
    end

    def pathname=(value)
      v = value.to_s
      v = "/#{v}" if !v.start_with?("/") && !v.empty?
      @uri.path = v
    end

    def search
      q = @search_params.to_s
      q.empty? ? "" : "?#{q}"
    end

    def search=(value)
      q = value.to_s.sub(/^\?/, "")
      @search_params.__replace__(q)
      sync_uri_query
    end

    def hash
      f = @uri.fragment.to_s
      f.empty? ? "" : "##{f}"
    end

    def hash=(value)
      f = value.to_s.sub(/^#/, "")
      @uri.fragment = f.empty? ? nil : f
    end

    def origin
      return "null" unless @uri.scheme && @uri.host

      port_part = (@uri.port && @uri.port != @uri.default_port) ? ":#{@uri.port}" : ""
      "#{@uri.scheme}://#{@uri.host}#{port_part}"
    end

    def username
      @uri.user.to_s
    end

    def username=(value)
      @uri.user = value.to_s.empty? ? nil : value.to_s
    end

    def password
      @uri.password.to_s
    end

    def password=(value)
      @uri.password = value.to_s.empty? ? nil : value.to_s
    end

    def to_s
      href
    end

    def to_json(*_args)
      # match JSON.stringify(url) -> "\"<href>\""
      href.inspect
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "protocol"
        protocol
      when "host"
        host
      when "hostname"
        hostname
      when "port"
        port
      when "pathname"
        pathname
      when "search"
        search
      when "hash"
        hash
      when "origin"
        origin
      when "username"
        username
      when "password"
        password
      when "searchParams"
        @search_params
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        self.href = value
      when "protocol"
        self.protocol = value
      when "host"
        self.host = value
      when "hostname"
        self.hostname = value
      when "port"
        self.port = value
      when "pathname"
        self.pathname = value
      when "search"
        self.search = value
      when "hash"
        self.hash = value
      when "username"
        self.username = value
      when "password"
        self.password = value
      end

      nil
    end

    def __js_call__(method, _args)
      case method
      when "toString", "toJSON"
        href
      end
    end

    # Called by URLSearchParams when it mutates; we need to keep the
    # underlying URI's query string in sync so subsequent `href` is
    # accurate.
    def __notify_params_changed__
      sync_uri_query
    end

    private

    def parse_with_base(input, base)
      str = input.to_s
      uri = nil
      if base
        base_uri = base.is_a?(URL) ? URI.parse(base.href) : URI.parse(base.to_s)
        uri = URI.join(base_uri, str)
      else
        uri = URI.parse(str)
        raise DOMException::SyntaxError, "Invalid URL: #{str}" unless uri.scheme
      end

      uri
    rescue URI::InvalidURIError => e
      raise DOMException::SyntaxError, "Invalid URL: #{e.message}"
    end

    def build_href
      out = +""
      out << "#{@uri.scheme}:" if @uri.scheme
      if @uri.host
        out << "//"
        if @uri.user
          out << @uri.user
          out << ":#{@uri.password}" if @uri.password
          out << "@"
        end

        out << @uri.host
        out << ":#{@uri.port}" if @uri.port && @uri.port != @uri.default_port
      end

      out << @uri.path.to_s
      out << search
      out << hash
      out
    end

    def sync_uri_query
      q = @search_params.to_s
      @uri.query = q.empty? ? nil : q
    end
  end

  # `URLSearchParams` — query-string manipulation. Constructed from a
  # raw string (`"a=1&b=2"`), an array of `[k, v]` pairs, or a Hash.
  # Order is preserved. Values are stringified per spec.
  class URLSearchParams
    include Enumerable

    def initialize(input = "", owner: nil)
      @owner = owner
      @pairs = parse(input)
    end

    def get(name)
      pair = @pairs.find { |k, _| k == name.to_s }
      pair && pair[1]
    end

    def get_all(name)
      @pairs.select { |k, _| k == name.to_s }.map { |_, v| v }
    end

    alias getAll get_all

    def has(name)
      @pairs.any? { |k, _| k == name.to_s }
    end

    alias has? has

    def set(name, value)
      key = name.to_s
      first_done = false
      @pairs = @pairs.reject do |k, _|
        next false unless k == key

        if first_done
          true
        else
          first_done = true
          false
        end
      end

      @pairs.map! { |pair| pair[0] == key ? [key, value.to_s] : pair }
      @pairs << [key, value.to_s] unless first_done
      notify
      nil
    end

    def append(name, value)
      @pairs << [name.to_s, value.to_s]
      notify
      nil
    end

    def delete(name, value = nil)
      key = name.to_s
      if value.nil?
        @pairs.reject! { |k, _| k == key }
      else
        v = value.to_s
        @pairs.reject! { |k, vv| k == key && vv == v }
      end

      notify
      nil
    end

    def sort
      @pairs.sort_by! { |k, _| k }
      notify
      nil
    end

    def size
      @pairs.length
    end

    alias length size

    def each(&block)
      @pairs.each(&block)
    end

    def keys
      @pairs.map { |k, _| k }
    end

    def values
      @pairs.map { |_, v| v }
    end

    def entries
      @pairs.dup
    end

    def for_each(&block)
      @pairs.each { |k, v| block.call(v, k, self) }
      nil
    end

    alias forEach for_each

    def to_s
      @pairs.map { |k, v| "#{encode(k)}=#{encode(v)}" }.join("&")
    end

    def __replace__(query_string)
      @pairs = parse(query_string)
      nil
    end

    def __js_get__(key)
      case key
      when "size", "length"
        size
      end
    end

    def __js_call__(method, args)
      case method
      when "get"
        get(args[0])
      when "getAll"
        get_all(args[0])
      when "has"
        has(args[0])
      when "set"
        set(args[0], args[1])
      when "append"
        append(args[0], args[1])
      when "delete"
        delete(args[0], args[1])
      when "sort"
        sort
      when "toString"
        to_s
      when "forEach"
        for_each(&args[0])
      when "keys"
        keys
      when "values"
        values
      when "entries"
        entries
      end
    end

    private

    def parse(input)
      case input
      when Array
        input.map { |k, v| [k.to_s, v.to_s] }
      when Hash
        input.map { |k, v| [k.to_s, v.to_s] }
      else
        s = input.to_s.sub(/^\?/, "")
        return [] if s.empty?

        s.split("&").map do |pair|
          k, v = pair.split("=", 2)
          [CGI.unescape(k.to_s), CGI.unescape(v.to_s)]
        end
      end
    end

    def encode(str)
      CGI.escape(str.to_s)
    end

    def notify
      @owner&.__notify_params_changed__
    end
  end
end
