# frozen_string_literal: true

require "time"

module Dommy
  # One browsing session's cookie store (RFC 6265bis, "Cookies: HTTP State
  # Management Mechanism"): what `document.cookie` and `cookieStore` read and
  # write, and — through an embedder that sends requests — what a request's
  # `Cookie` header carries and a response's `Set-Cookie` stores.
  #
  # A cookie is keyed by name, domain (host-only or not) and path, and stored
  # with the RFC's attribute processing: Expires / Max-Age (capped at 400
  # days; a past one deletes), Domain (which must domain-match the request
  # host), Path (default-path from the URL), Secure (only from a secure URL:
  # https, wss, or a loopback host, as browsers treat http://localhost),
  # HttpOnly (refused from, and hidden from, a "non-HTTP" API such as
  # `document.cookie`), SameSite, the `__Secure-` / `__Host-` prefixes, and the
  # limits (name + value at most 4096 octets, an attribute value at most 1024).
  # A cookie string with a control character is ignored whole.
  #
  # `http: false` marks the "non-HTTP" APIs. Thread-safe: an embedder's network
  # workers may store and read while the page thread does.
  #
  # Not modelled: a public suffix list (a single-label Domain is refused unless
  # it is the host itself), SameSite enforcement on retrieval (every request
  # counts as same-site), and per-domain cookie count limits.
  class CookieJar
    Cookie = Struct.new(
      :name, :value, :domain, :path, :expires, :secure, :http_only, :host_only,
      :same_site, :creation, keyword_init: true
    ) do
      # `expires` is a Time, or nil for a session cookie.
      def persistent? = !expires.nil?
    end

    MAX_NAME_VALUE_OCTETS = 4096
    MAX_ATTRIBUTE_VALUE_OCTETS = 1024
    MAX_AGE_CAP_SECONDS = 400 * 24 * 60 * 60
    # %x00-08 / %x0A-1F / %x7F: every control character but HTAB.
    CONTROL_CHARACTERS = /[\x00-\x08\x0A-\x1F\x7F]/
    EARLIEST = Time.at(0).utc

    def initialize(clock: nil)
      @cookies = []
      @clock = clock || -> { Time.now }
      @sequence = 0
      @mutex = Mutex.new
    end

    # "Receive a set-cookie-string" from `url`: parse it and store the cookie
    # it describes (a past expiry deletes its match). `http: false` for a
    # non-HTTP API. Returns the stored Cookie, or nil when it was ignored.
    def store(set_cookie_string, url, http: true)
      parsed = parse(set_cookie_string.to_s)
      return nil unless parsed

      record = request_record(url)
      return nil unless record

      @mutex.synchronize { store_parsed(parsed, record, http) }
    end

    # Store every `Set-Cookie` of a response's headers (a Hash whose value is
    # a String — several cookies separated by newlines, as Rack joins them —
    # or an Array; or an Array of [name, value] pairs) received from `url`.
    def store_response_headers(headers, url)
      set_cookie_values(headers).each { |value| store(value, url, http: true) }
      nil
    end

    # The cookie-string for a request to `url` (`http: false` leaves out
    # HttpOnly cookies): matching cookies, longer paths first, then oldest.
    def cookie_string(url, http: true)
      matching(url, http: http).map { |c| c.name.empty? ? c.value : "#{c.name}=#{c.value}" }.join("; ")
    end

    # The cookies a request to `url` would carry, in cookie-string order.
    def matching(url, http: true)
      record = request_record(url)
      return [] unless record

      host = record[:host]
      path = record[:path]
      secure = record[:secure]
      found = @mutex.synchronize do
        evict_expired
        @cookies.select do |c|
          domain_matches_cookie?(c, host) && path_match?(c.path, path) &&
            (!c.secure || secure) && (http || !c.http_only)
        end
      end
      found.sort_by { |c| [-c.path.length, c.creation] }
    end

    # Every unexpired cookie.
    def all
      @mutex.synchronize do
        evict_expired
        @cookies.dup
      end
    end

    # The value of the first unexpired cookie named `name`, or nil.
    def get(name)
      all.find { |c| c.name == name.to_s }&.value
    end

    # Store a cookie as given, bypassing the request checks (an embedder or a
    # test setting up state). A nil `domain` makes it host-only for `host`.
    def set!(name, value, domain: nil, host: nil, path: "/", expires: nil, secure: false, http_only: false,
             same_site: nil, host_only: nil)
      dom = (domain || host || "").to_s.sub(/\A\./, "").downcase
      cookie = Cookie.new(
        name: name.to_s, value: value.to_s, domain: dom, path: path || "/", expires: expires,
        secure: secure ? true : false, http_only: http_only ? true : false,
        host_only: host_only.nil? ? domain.nil? : host_only, same_site: same_site
      )
      @mutex.synchronize { insert(cookie) }
      cookie
    end

    # Remove the cookie named `name` with this domain and path (any, when
    # nil).
    def delete(name, domain: nil, path: nil)
      @mutex.synchronize do
        @cookies.reject! do |c|
          c.name == name.to_s && (domain.nil? || c.domain == domain.to_s.sub(/\A\./, "").downcase) &&
            (path.nil? || c.path == path)
        end
      end
      nil
    end

    def clear
      @mutex.synchronize { @cookies = [] }
      nil
    end

    # Every unexpired cookie as a plain Hash, for #import!.
    def export
      all.map { |c| c.to_h.except(:creation) }
    end

    # Restore a cookie from an #export Hash (symbol or string keys), keeping
    # its host-only flag; an expired one is skipped.
    def import!(attrs)
      h = attrs.to_h.transform_keys(&:to_sym)
      expires = h[:expires]
      expires = Time.parse(expires) if expires.is_a?(String)
      cookie = Cookie.new(
        name: h[:name].to_s, value: h[:value].to_s, domain: h[:domain].to_s.sub(/\A\./, "").downcase,
        path: h[:path] || "/", expires: expires, secure: h[:secure] ? true : false,
        http_only: h[:http_only] ? true : false, host_only: h[:host_only] ? true : false,
        same_site: h[:same_site]
      )
      @mutex.synchronize { insert(cookie) unless expired?(cookie) }
      nil
    end

    # The jar's current time (a Time), which its expiries are measured
    # against.
    def now = @clock.call

    private

    def set_cookie_values(headers)
      pairs = headers.respond_to?(:each_pair) ? headers.each_pair.to_a : Array(headers)
      pairs.flat_map do |name, value|
        next [] unless name.to_s.casecmp?("set-cookie")

        Array(value).flat_map { |v| v.to_s.split("\n") }
      end
    end

    # RFC 6265bis §5.6 "The Set-Cookie Header Field": the name, value and
    # recognized attributes, or nil for a string to ignore.
    def parse(string)
      return nil if string.match?(CONTROL_CHARACTERS)

      name_value, _, unparsed = string.partition(";")
      if name_value.include?("=")
        name, _, value = name_value.partition("=")
      else
        name = ""
        value = name_value
      end
      name = trim(name)
      value = trim(value)
      return nil if name.bytesize + value.bytesize > MAX_NAME_VALUE_OCTETS

      attrs = {}
      unparsed.split(";").each do |av|
        key, _, val = av.partition("=")
        key = trim(key).downcase
        val = trim(val)
        next if val.bytesize > MAX_ATTRIBUTE_VALUE_OCTETS

        process_attribute(attrs, key, val)
      end
      {name: name, value: value, attrs: attrs}
    end

    def trim(string) = string.to_s.gsub(/\A[ \t]+|[ \t]+\z/, "")

    def process_attribute(attrs, key, val)
      case key
      when "expires"
        time = parse_cookie_date(val)
        attrs[:expires] = time if time
      when "max-age"
        return unless val.match?(/\A-?\d+\z/)

        attrs[:max_age] = val.to_i
      when "domain"
        attrs[:domain] = val.sub(/\A\./, "").downcase unless val.empty?
      when "path"
        attrs[:path] = val.start_with?("/") ? val : nil
        attrs[:path_given] = true
      when "secure"
        attrs[:secure] = true
      when "httponly"
        attrs[:http_only] = true
      when "samesite"
        attrs[:same_site] = {"strict" => "Strict", "lax" => "Lax", "none" => "None"}.fetch(val.downcase, "Default")
      end
    end

    # RFC 6265bis §5.7 "Storage Model", given the parsed string.
    def store_parsed(parsed, record, http)
      name = parsed[:name]
      value = parsed[:value]
      attrs = parsed[:attrs]
      return nil if name.empty? && value.empty?
      # A cookie with no name must not look like a prefixed one.
      return nil if name.empty? && value.match?(/\A__(secure|host)-/i)

      expires = expiry_of(attrs)
      host = record[:host]
      domain_attr = attrs[:domain].to_s
      if !domain_attr.empty? && public_suffix?(domain_attr)
        return nil unless domain_attr == host

        domain_attr = ""
      end
      if domain_attr.empty?
        host_only = true
        domain = host
      else
        return nil unless domain_match?(host, domain_attr)

        host_only = false
        domain = domain_attr
      end
      path = attrs[:path] || default_path(record[:path])
      secure = attrs[:secure] == true
      return nil if secure && !record[:secure]

      http_only = attrs[:http_only] == true
      return nil if http_only && !http
      # Leave secure cookies alone: an insecure request cannot shadow one.
      return nil if !secure && !record[:secure] && shadows_secure_cookie?(name, domain, path)

      same_site = attrs[:same_site] || "Default"
      return nil if same_site == "None" && !secure
      return nil if name.match?(/\A__secure-/i) && !secure
      return nil if name.match?(/\A__host-/i) && !(secure && host_only && path == "/")

      cookie = Cookie.new(name: name, value: value, domain: domain, path: path, expires: expires,
                          secure: secure, http_only: http_only, host_only: host_only, same_site: same_site)
      old = @cookies.find { |c| same_key?(c, cookie) }
      return nil if old&.http_only && !http

      if expired?(cookie)
        @cookies.delete(old) if old
        return nil
      end
      insert(cookie, creation: old&.creation)
      cookie
    end

    def same_key?(a, b)
      a.name == b.name && a.domain == b.domain && a.host_only == b.host_only && a.path == b.path
    end

    def insert(cookie, creation: nil)
      @cookies.reject! { |c| same_key?(c, cookie) }
      cookie.creation = creation || (@sequence += 1)
      @cookies << cookie
      cookie
    end

    # RFC 6265bis "Storage Model" step 16: a secure cookie of the name whose
    # domain matches either way, and under whose path the new cookie's path
    # falls (the new path path-matches the stored one).
    def shadows_secure_cookie?(name, domain, path)
      @cookies.any? do |c|
        c.secure && c.name == name &&
          (domain_match?(domain, c.domain) || domain_match?(c.domain, domain)) && path_match?(c.path, path)
      end
    end

    # Max-Age wins over Expires; both are capped at 400 days, and a Max-Age of
    # zero or less is the earliest representable time (an immediate delete).
    def expiry_of(attrs)
      cap = now + MAX_AGE_CAP_SECONDS
      if attrs.key?(:max_age)
        seconds = attrs[:max_age]
        return EARLIEST if seconds <= 0

        return [now + seconds, cap].min
      end
      return nil unless attrs[:expires]

      [attrs[:expires], cap].min
    end

    def expired?(cookie)
      cookie.expires && cookie.expires <= now
    end

    def evict_expired
      @cookies.reject! { |c| expired?(c) }
    end

    # A single-label domain stands in for a public suffix (no list here).
    def public_suffix?(domain)
      !domain.include?(".") && !ip_address?(domain)
    end

    def ip_address?(host)
      host.match?(/\A\d+\.\d+\.\d+\.\d+\z/) || host.start_with?("[")
    end

    # RFC 6265bis "domain-match".
    def domain_match?(string, domain)
      return true if string == domain
      return false if ip_address?(string)

      string.end_with?(".#{domain}")
    end

    def domain_matches_cookie?(cookie, host)
      cookie.host_only ? cookie.domain == host : domain_match?(host, cookie.domain)
    end

    # RFC 6265bis "path-match".
    def path_match?(cookie_path, request_path)
      return true if cookie_path == request_path
      return false unless request_path.start_with?(cookie_path)

      cookie_path.end_with?("/") || request_path[cookie_path.length] == "/"
    end

    # RFC 6265bis "default-path" of a request path.
    def default_path(request_path)
      return "/" if request_path.empty? || !request_path.start_with?("/")

      idx = request_path.rindex("/")
      idx.zero? ? "/" : request_path[0...idx]
    end

    # The host, path and whether the URL is secure (a "secure protocol" is the
    # user agent's call: https, wss, and — as Chrome and Firefox do — a
    # loopback host), for an http(s)/ws(s) URL; nil for any other.
    def request_record(url)
      record = Internal::UrlParser.parse(url.to_s)
      return nil unless %w[http https ws wss].include?(record.scheme)

      host = record.host.to_s.downcase
      path = Internal::UrlParser.serialize_path(record)
      secure = %w[https wss].include?(record.scheme) || Internal::Origin.trustworthy_record?(record)
      {host: host, path: path.empty? ? "/" : path, secure: secure}
    rescue Internal::UrlParser::Failure
      nil
    end

    MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
    DATE_DELIMITER = /[\x09\x20-\x2F\x3B-\x40\x5B-\x60\x7B-\x7E]+/

    # RFC 6265bis §5.1.1 "Dates": the cookie-date parsing algorithm. nil when
    # the string is not a date.
    def parse_cookie_date(string)
      time = day = month = year = nil
      string.split(DATE_DELIMITER).each do |token|
        next if token.empty?

        if time.nil? && (m = token.match(/\A(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\D.*)?\z/))
          time = m.captures.map(&:to_i)
        elsif day.nil? && (m = token.match(/\A(\d{1,2})(?:\D.*)?\z/))
          day = m[1].to_i
        elsif month.nil? && (idx = MONTHS.index(token[0, 3].downcase))
          month = idx + 1
        elsif year.nil? && (m = token.match(/\A(\d{2,4})(?:\D.*)?\z/))
          year = m[1].to_i
        end
      end
      return nil unless time && day && month && year

      year += 1900 if year.between?(70, 99)
      year += 2000 if year.between?(0, 69)
      return nil if day < 1 || day > 31 || year < 1601 || time[0] > 23 || time[1] > 59 || time[2] > 59

      Time.utc(year, month, day, *time)
    rescue ArgumentError
      nil
    end
  end
end
