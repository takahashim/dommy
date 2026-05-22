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
      default = default_port_for(@uri.scheme.to_s.downcase)
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
      # WHATWG: a non-ASCII hostname assigned through the setter is
      # Punycode-encoded before storage (matches `new URL("...")`).
      @uri.host = Internal::IDNA.to_ascii(value.to_s)
    end

    def port
      default = default_port_for(@uri.scheme.to_s.downcase)
      return "" if @uri.port.nil? || @uri.port == default

      @uri.port.to_s
    end

    def port=(value)
      @uri.port = value.to_s.empty? ? nil : value.to_i
    end

    # WHATWG: for opaque-body schemes (javascript:, mailto:, data:,
    # tel:, blob:) the body sits in `URI`'s `opaque` slot, not `path`.
    # For special schemes (http/https/ws/wss/ftp), an empty path is
    # canonicalized to `"/"`.
    def pathname
      opaque = @uri.respond_to?(:opaque) ? @uri.opaque : nil
      return opaque.to_s if opaque

      path = @uri.path.to_s
      return "/" if path.empty? && special_scheme?

      path
    end

    def pathname=(value)
      v = value.to_s
      v = "/#{v}" if !v.start_with?("/") && !v.empty?
      @uri.path = v
    end

    # WHATWG: `url.search` is the raw query string (with `?` prefix),
    # preserving percent-encoding and stray `?` characters as parsed.
    # `url.searchParams.toString()` re-serializes via the form-encoded
    # contract (`+` for space, etc.) — distinct from `url.search`.
    def search
      q = @uri.query
      q.nil? || q.empty? ? "" : "?#{q}"
    end

    def search=(value)
      q = value.to_s.sub(/^\?/, "")
      @uri.query = q.empty? ? nil : q
      @search_params.__replace__(q)
    end

    def hash
      f = @uri.fragment.to_s
      f.empty? ? "" : "##{f}"
    end

    def hash=(value)
      f = value.to_s.sub(/^#/, "")
      @uri.fragment = f.empty? ? nil : f
    end

    # WHATWG URL §origin. Tuple origins for http(s) / ws(s) / ftp;
    # `"null"` for file/data/javascript/etc. Blob URLs unwrap their
    # inner URL recursively.
    def origin
      scheme = @uri.scheme.to_s.downcase
      return blob_inner_origin if scheme == "blob"
      return "null" unless TUPLE_ORIGIN_SCHEMES.include?(scheme)
      return "null" unless @uri.host

      default = default_port_for(scheme)
      port_part = (@uri.port && @uri.port != default) ? ":#{@uri.port}" : ""
      "#{scheme}://#{@uri.host}#{port_part}"
    end

    def blob_inner_origin
      # `blob:<inner-url>` — the body after `blob:` is itself a URL
      # whose origin we adopt. Anything that fails to parse falls
      # back to "null".
      opaque = @uri.respond_to?(:opaque) ? @uri.opaque : nil
      return "null" if opaque.nil? || opaque.empty?

      URL.new(opaque).origin
    rescue DOMException::SyntaxError
      "null"
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

    SPECIAL_SCHEMES = %w[http https ws wss ftp file].freeze

    # WHATWG: only http(s) / ws(s) / ftp produce a tuple origin. file
    # / data / javascript / etc. resolve to `"null"`. `blob:` is
    # handled specially (inner-URL origin).
    TUPLE_ORIGIN_SCHEMES = %w[http https ws wss ftp].freeze

    # Default ports per scheme (Ruby URI knows http/https/ftp; we add
    # ws/wss).
    DEFAULT_PORTS = {
      "http" => 80,
      "https" => 443,
      "ws" => 80,
      "wss" => 443,
      "ftp" => 21
    }.freeze

    # Chars that Ruby URI rejects in the path/query/fragment portion
    # but WHATWG silently percent-encodes.
    UNSAFE_PATH_CHARS = /[ "<>`{}|\\\^\[\]]/

    private

    def special_scheme?
      SPECIAL_SCHEMES.include?(@uri.scheme.to_s.downcase)
    end

    def default_port_for(scheme)
      DEFAULT_PORTS[scheme]
    end

    def parse_with_base(input, base)
      str = preprocess(input.to_s)
      uri = nil
      if base
        base_str = preprocess(base.is_a?(URL) ? base.href : base.to_s)
        base_uri = URI.parse(base_str)
        uri = URI.join(base_uri, str)
      else
        uri = URI.parse(str)
        raise DOMException::SyntaxError, "Invalid URL: #{str}" unless uri.scheme
      end

      normalize_path_segments(uri) if special_scheme_for?(uri)
      uri
    rescue URI::InvalidURIError => e
      raise DOMException::SyntaxError, "Invalid URL: #{e.message}"
    rescue Internal::Punycode::Error, Internal::IDNA::Error => e
      raise DOMException::SyntaxError, "Invalid URL host: #{e.message}"
    end

    # WHATWG URL preprocessing — turn a raw input string into a form
    # Ruby URI accepts. Order matters: each step can depend on
    # earlier normalizations.
    def preprocess(str)
      str = strip_c0_and_space(str)
      str = strip_tab_and_newline(str)
      str = replace_backslashes_for_special_scheme(str)
      str = normalize_idn_host(str)
      str = normalize_ipv4_host(str)
      percent_encode_unsafe(str)
    end

    # WHATWG §basic-url-parser step 1: strip leading and trailing
    # C0 controls and ASCII space.
    def strip_c0_and_space(str)
      str.sub(/\A[\x00-\x20]+/, "").sub(/[\x00-\x20]+\z/, "")
    end

    # WHATWG: remove ASCII tab and newline anywhere in the URL.
    def strip_tab_and_newline(str)
      str.delete("\t\n\r")
    end

    # WHATWG: for special-scheme URLs, treat `\` as `/` in the
    # authority and path portions.
    def replace_backslashes_for_special_scheme(str)
      m = str.match(/\A([a-zA-Z][a-zA-Z0-9+.\-]*):/)
      return str unless m
      return str unless SPECIAL_SCHEMES.include?(m[1].downcase)

      scheme_end = m.end(0)
      str[0...scheme_end] + str[scheme_end..].tr("\\", "/")
    end

    # Percent-encode chars after the authority section that Ruby URI
    # would reject (space, `<`, `>`, `{`, `}`, `|`, etc.) and any
    # non-ASCII byte. Preserves already-encoded `%XX` sequences.
    def percent_encode_unsafe(str)
      m = str.match(%r{\A([a-zA-Z][a-zA-Z0-9+.\-]*:(?://[^/?#]*)?)(.*)\z}m)
      return str unless m

      prefix = m[1]
      tail = m[2]
      out = +""
      i = 0
      while i < tail.length
        c = tail[i]
        if c == "%" && tail[i + 1, 2].to_s.match?(/\A[0-9A-Fa-f]{2}\z/)
          out << tail[i, 3]
          i += 3
          next
        end

        needs_encoding = c.bytesize > 1 ||
          c.ord < 0x20 ||
          c.ord == 0x7F ||
          UNSAFE_PATH_CHARS.match?(c)

        if needs_encoding
          c.bytes.each { |b| out << format("%%%02X", b) }
        else
          out << c
        end

        i += 1
      end

      prefix + out
    end

    # Detect dotted-quad / hex / octal / short-form IPv4 hosts and
    # canonicalize to dotted-decimal. Touches the authority section
    # only; non-special schemes are skipped.
    def normalize_ipv4_host(str)
      m = str.match(%r{\A([a-zA-Z][a-zA-Z0-9+.\-]*://(?:[^@/?#]*@)?)([^/:?#]+)(.*)\z}m)
      return str unless m

      scheme = str.match(/\A([a-zA-Z][a-zA-Z0-9+.\-]*):/)[1].downcase
      return str unless SPECIAL_SCHEMES.include?(scheme)

      ip = Internal::Ipv4Parser.parse(m[2])
      return str unless ip

      "#{m[1]}#{ip}#{m[3]}"
    end

    def special_scheme_for?(uri)
      SPECIAL_SCHEMES.include?(uri.scheme.to_s.downcase)
    end

    # WHATWG: resolve `.` / `..` path segments. Applied only to
    # special-scheme URIs (opaque schemes' path is verbatim).
    def normalize_path_segments(uri)
      path = uri.path
      return if path.nil? || path.empty?

      segments = path.split("/", -1)
      result = []
      segments.each do |seg|
        case seg
        when ".."
          # Pop unless we'd remove the leading-empty marker.
          result.pop if result.length > 1
        when "."
          # Skip.
        else
          result << seg
        end
      end

      # Preserve the trailing slash if the input had one.
      result << "" if path.end_with?("/", ".") && result.last != ""
      uri.path = result.join("/")
    end

    # WHATWG: non-ASCII host labels must be Punycode-encoded
    # (`日本.test` → `xn--wgv71a.test`) before storage. Ruby's URI
    # parser rejects non-ASCII hosts outright, so we rewrite the host
    # portion of the authority section here. Userinfo / port / path /
    # query / fragment are left untouched.
    def normalize_idn_host(str)
      return str unless str.is_a?(String)
      return str unless str.match?(%r{://})

      str.sub(%r{(://)([^/?#]*)}) do
        sep = Regexp.last_match(1)
        authority = Regexp.last_match(2)
        sep + rewrite_authority(authority)
      end
    end

    def rewrite_authority(authority)
      userinfo, hostport = authority.include?("@") ? authority.split("@", 2) : [nil, authority]
      host, port = hostport.rpartition(":").then { |h, sep, p|
        sep.empty? || h.empty? ? [hostport, nil] : [h, p]
      }

      ascii_host = Internal::IDNA.to_ascii(host)
      out = +""
      out << "#{userinfo}@" if userinfo
      out << ascii_host
      out << ":#{port}" if port
      out
    end

    def build_href
      out = +""
      out << "#{@uri.scheme}:" if @uri.scheme

      opaque = @uri.respond_to?(:opaque) ? @uri.opaque : nil
      if opaque
        # Opaque-body scheme (javascript:, mailto:, data:, tel:, blob:)
        # — emit the body verbatim, no authority section.
        out << opaque
      else
        if @uri.host
          out << "//"
          if @uri.user
            out << @uri.user
            out << ":#{@uri.password}" if @uri.password
            out << "@"
          end

          out << @uri.host
          default = default_port_for(@uri.scheme.to_s.downcase)
          out << ":#{@uri.port}" if @uri.port && @uri.port != default
        end

        path = @uri.path.to_s
        # WHATWG: for special schemes the path is normalized to `/`
        # when empty (matches `pathname` accessor).
        path = "/" if path.empty? && special_scheme?
        out << path
      end

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
