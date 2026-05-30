# frozen_string_literal: true

require "uri"
require "cgi"
require_relative "internal/url_parser"

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
      # `URL.__test_resolve_blob_url__(url)`. Returns nil for non-Blob input.
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
      def __test_resolve_blob_url__(url)
        @blob_urls[url.to_s]
      end

      # Test seam: drop all registered blob URLs.
      def __test_reset_blob_urls__
        @blob_urls.clear
      end

      # WHATWG URL Standard — `URL.parse(input, base)` is the
      # non-throwing static factory. Returns a URL on success, `nil`
      # on parse failure. The constructor (`new URL(...)`) raises
      # `SyntaxError` for the same failure case.
      def parse(input, base = nil)
        new(input, base)
      rescue DOMException::SyntaxError
        nil
      end

      # WHATWG URL Standard — `URL.canParse(input, base)`. Boolean
      # counterpart to `parse`: lets callers peek at validity
      # without rescuing an exception or holding a URL reference.
      def can_parse(input, base = nil)
        !parse(input, base).nil?
      end
    end

  attr_reader :search_params

  def initialize(input, base = nil)
    # An explicit JS `undefined` base means "no base" (WebIDL optional arg),
    # distinct from a string base. (JS null already arrives as nil.)
    base = nil if base.equal?(Bridge::UNDEFINED)
    base_str = base.is_a?(URL) ? base.href : base
    @record = Internal::UrlParser.parse(input.to_s, base_str)
    @search_params = URLSearchParams.new(@record.query.to_s, owner: self)
  rescue Internal::UrlParser::Failure => e
    raise DOMException::SyntaxError, "Invalid URL: #{e.message}"
  end

  def href
    Internal::UrlParser.serialize(@record)
  end

  def href=(value)
    @record = Internal::UrlParser.parse(value.to_s, nil)
    @search_params.__internal_replace__(@record.query.to_s)
    href
  rescue Internal::UrlParser::Failure => e
    raise DOMException::SyntaxError, "Invalid URL: #{e.message}"
  end

  def protocol
    "#{@record.scheme}:"
  end

  def protocol=(value)
    s = value.to_s.sub(/:\z/, "").downcase
    @record.scheme = s if s.match?(/\A[a-z][a-z0-9+\-.]*\z/)
  end

  def host
    return "" if @record.host.nil?

    @record.port ? "#{@record.host}:#{@record.port}" : @record.host
  end

  def host=(value)
    h, sep, p = value.to_s.partition(":")
    begin
      @record.host = Internal::UrlParser.parse_host(h, @record.special?)
    rescue Internal::UrlParser::Failure
      return
    end
    self.port = p unless sep.empty?
  end

  def hostname
    @record.host.to_s
  end

  def hostname=(value)
    @record.host = Internal::UrlParser.parse_host(value.to_s, @record.special?)
  rescue Internal::UrlParser::Failure
    nil
  end

  def port
    @record.port.nil? ? "" : @record.port.to_s
  end

  def port=(value)
    v = value.to_s
    if v.empty?
      @record.port = nil
    elsif v.match?(/\A[0-9]+\z/)
      n = v.to_i
      @record.port = (n == @record.default_port ? nil : n) if n <= 65_535
    end
  end

  def pathname
    Internal::UrlParser.serialize_path(@record)
  end

  def pathname=(value)
    return if @record.opaque_path?

    v = value.to_s
    v = v.tr("\\", "/") if @record.special?
    segs = v.split("/", -1)
    segs.shift if segs.first == ""
    set = Internal::UrlParser.method(:path_set?)
    @record.path = segs.map { |s| s.each_char.map { |ch| Internal::UrlParser.pe(ch, set) }.join }
    @record.path = [""] if @record.path.empty? && @record.special?
  end

  def search
    q = @record.query
    q.nil? || q.empty? ? "" : "?#{q}"
  end

  def search=(value)
    v = value.to_s.sub(/\A\?/, "")
    if v.empty?
      @record.query = nil
    else
      set = @record.special? ? Internal::UrlParser.method(:special_query_set?) : Internal::UrlParser.method(:query_set?)
      @record.query = v.each_char.map { |ch| Internal::UrlParser.pe(ch, set) }.join
    end
    @search_params.__internal_replace__(@record.query.to_s)
  end

  def hash
    f = @record.fragment
    f.nil? || f.empty? ? "" : "##{f}"
  end

  def hash=(value)
    v = value.to_s.sub(/\A#/, "")
    if v.empty?
      @record.fragment = nil
    else
      set = Internal::UrlParser.method(:fragment_set?)
      @record.fragment = v.each_char.map { |ch| Internal::UrlParser.pe(ch, set) }.join
    end
  end

  # WHATWG URL §origin. Tuple origins for http(s) / ws(s) / ftp; `"null"`
  # for file/data/javascript/etc. Blob URLs unwrap their inner URL.
  def origin
    scheme = @record.scheme
    return blob_inner_origin if scheme == "blob"
    return "null" unless TUPLE_ORIGIN_SCHEMES.include?(scheme)
    return "null" if @record.host.nil?

    port_part = @record.port ? ":#{@record.port}" : ""
    "#{scheme}://#{@record.host}#{port_part}"
  end

  def username
    @record.username
  end

  def username=(value)
    return if cannot_have_credentials?

    set = Internal::UrlParser.method(:userinfo_set?)
    @record.username = value.to_s.each_char.map { |ch| Internal::UrlParser.pe(ch, set) }.join
  end

  def password
    @record.password
  end

  def password=(value)
    return if cannot_have_credentials?

    set = Internal::UrlParser.method(:userinfo_set?)
    @record.password = value.to_s.each_char.map { |ch| Internal::UrlParser.pe(ch, set) }.join
  end

  def to_s
    href
  end

  def to_json(*_args)
    href.inspect
  end

  def __js_get__(key)
    case key
    when "href" then href
    when "protocol" then protocol
    when "host" then host
    when "hostname" then hostname
    when "port" then port
    when "pathname" then pathname
    when "search" then search
    when "hash" then hash
    when "origin" then origin
    when "username" then username
    when "password" then password
    when "searchParams" then @search_params
    end
  end

  def __js_set__(key, value)
    case key
    when "href" then self.href = value
    when "protocol" then self.protocol = value
    when "host" then self.host = value
    when "hostname" then self.hostname = value
    when "port" then self.port = value
    when "pathname" then self.pathname = value
    when "search" then self.search = value
    when "hash" then self.hash = value
    when "username" then self.username = value
    when "password" then self.password = value
    else
      return Bridge::UNHANDLED
    end

    nil
  end

  include Bridge::Methods
  js_methods %w[toString toJSON]
  def __js_call__(method, _args)
    case method
    when "toString", "toJSON"
      href
    end
  end

  # Called by URLSearchParams when it mutates; keep the record's query in sync.
  def __internal_notify_params_changed__
    q = @search_params.to_s
    @record.query = q.empty? ? nil : q
  end

  # WHATWG: only http(s) / ws(s) / ftp produce a tuple origin. file / data /
  # javascript / etc. resolve to `"null"`. `blob:` is handled specially.
  TUPLE_ORIGIN_SCHEMES = %w[http https ws wss ftp].freeze

  private

  def cannot_have_credentials?
    @record.host.nil? || @record.host == "" || @record.scheme == "file"
  end

  def blob_inner_origin
    return "null" unless @record.opaque_path?

    body = @record.path
    return "null" if body.nil? || body.empty?

    URL.new(body).origin
  rescue DOMException::SyntaxError
    "null"
  end
  end

  class URLSearchParams
    include Enumerable

    # Sentinel distinguishing "no second argument" from an explicit null/value
    # in the two-argument has()/delete() forms.
    UNSET = Object.new
    private_constant :UNSET

    def initialize(input = "", owner: nil)
      @owner = owner
      @pairs = parse(input)
    end

    def get(name)
      key = stringify(name)
      pair = @pairs.find { |k, _| k == key }
      pair && pair[1]
    end

    def get_all(name)
      key = stringify(name)
      @pairs.select { |k, _| k == key }.map { |_, v| v }
    end

    alias getAll get_all

    # WHATWG has(name) / has(name, value): with a value, only matches a pair
    # whose value also equals it.
    def has(name, value = UNSET)
      key = stringify(name)
      return @pairs.any? { |k, _| k == key } if UNSET.equal?(value)

      val = stringify(value)
      @pairs.any? { |k, v| k == key && v == val }
    end

    alias has? has

    def set(name, value)
      key = stringify(name)
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

      val = stringify(value)
      @pairs.map! { |pair| pair[0] == key ? [key, val] : pair }
      @pairs << [key, val] unless first_done
      notify
      nil
    end

    def append(name, value)
      @pairs << [stringify(name), stringify(value)]
      notify
      nil
    end

    # WHATWG delete(name) / delete(name, value): with a value, only removes
    # pairs whose value also matches.
    def delete(name, value = UNSET)
      key = stringify(name)
      if UNSET.equal?(value)
        @pairs.reject! { |k, _| k == key }
      else
        val = stringify(value)
        @pairs.reject! { |k, vv| k == key && vv == val }
      end

      notify
      nil
    end

    # WHATWG: sort by comparison of the names' UTF-16 *code units*
    # (not code points — so a surrogate-pair character sorts by its
    # leading 0xD800–0xDBFF unit), preserving the relative order of
    # pairs with equal names (Ruby's sort_by is not stable, hence the
    # index tiebreak).
    def sort
      @pairs = @pairs
        .each_with_index
        .sort_by { |(name, _value), idx| [name.encode(Encoding::UTF_16BE).unpack("n*"), idx] }
        .map(&:first)
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

    def __internal_replace__(query_string)
      @pairs = parse(query_string)
      nil
    end

    def __js_get__(key)
      case key
      when "size", "length"
        size
      end
    end

    include Bridge::Methods
    js_methods %w[get getAll has set append delete sort toString forEach keys values entries]
    def __js_call__(method, args)
      case method
      when "get"
        get(args[0])
      when "getAll"
        get_all(args[0])
      when "has"
        value_given?(args) ? has(args[0], args[1]) : has(args[0])
      when "set"
        set(args[0], args[1])
      when "append"
        append(args[0], args[1])
      when "delete"
        value_given?(args) ? delete(args[0], args[1]) : delete(args[0])
      when "sort"
        sort
      when "toString"
        to_s
      when "forEach"
        # The callback is a live JS function (HostCallback), not a Ruby Proc, so
        # invoke it through the bridge ABI rather than `&block` (which would try
        # to to_proc it). callback(value, key, this) per WHATWG.
        cb = args[0]
        @pairs.each do |k, v|
          if cb.respond_to?(:__js_call__)
            cb.__js_call__("call", [v, k, self])
          elsif cb.respond_to?(:call)
            cb.call(v, k, self)
          end
        end
        nil
      when "keys"
        keys
      when "values"
        values
      when "entries"
        entries
      end
    end

    private

    # True when a real second argument (value) was passed to has()/delete().
    # An explicit JS `undefined` counts as "not provided" (one-arg form).
    def value_given?(args)
      args.length >= 2 && !args[1].equal?(Bridge::UNDEFINED)
    end

    def parse(input)
      case input
      when Array
        input.map { |k, v| [k.to_s, v.to_s] }
      when Hash
        input.map { |k, v| [k.to_s, v.to_s] }
      else
        s = input.to_s.sub(/^\?/, "")
        return [] if s.empty?

        # WHATWG urlencoded parser: split on "&" and skip empty sequences (so
        # "a=b&&c" / trailing "&" don't yield phantom empty-name pairs).
        s.split("&").reject(&:empty?).map do |pair|
          k, v = pair.split("=", 2)
          [decode(k.to_s), decode(v.to_s)]
        end
      end
    end

    def decode(str)
      CGI.unescape(str)
    end

    # WHATWG application/x-www-form-urlencoded serializer: byte-encode, keeping
    # alphanumerics and *-._ literal, space as "+", everything else as %XX.
    # (CGI.escape differs — notably it percent-encodes "*".)
    def encode(str)
      str.to_s.b.gsub(/[^*\-._A-Za-z0-9]/n) { |c| c == " " ? "+" : format("%%%02X", c.ord) }
    end

    # USVString coercion for name/value arguments. JS null arrives as Ruby nil
    # and must stringify to "null" (ToString(null)), not "".
    def stringify(value)
      value.nil? ? "null" : value.to_s
    end

    def notify
      @owner&.__internal_notify_params_changed__
    end
  end
end
