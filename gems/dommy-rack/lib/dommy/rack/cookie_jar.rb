# frozen_string_literal: true

require "uri"
require "time"

module Dommy
  module Rack
    # A simplified, same-origin cookie store. Parses Set-Cookie response
    # headers, generates the Cookie request header, and applies domain, path,
    # expiry, and secure matching. No public-suffix handling.
    class CookieJar
      CookieEntry = Struct.new(
        :name, :value, :domain, :path, :expires, :secure, :http_only, :host_only,
        keyword_init: true
      )

      def initialize
        @entries = []
        # The jar is shared between the page thread (document.cookie) and network
        # worker threads (request Cookie headers + Set-Cookie storage), so every
        # touch of @entries is guarded. The lock is held only around the array
        # access (no I/O, no reentrancy into the jar), so it never serializes the
        # blocking HTTP itself.
        @mutex = Mutex.new
      end

      # Parse a single Set-Cookie header value and store the result.
      def store_from_header(set_cookie_string, request_url)
        uri = URI.parse(request_url)
        entry = parse_set_cookie(set_cookie_string, uri)
        return unless entry

        @mutex.synchronize do
          if expired?(entry)
            remove(entry.name, entry.domain, entry.path)
          else
            store_entry(entry)
          end
        end
      end

      # Manually store a cookie. domain defaults to host-only on request_host.
      def set!(name, value, domain: nil, path: "/", expires: nil, secure: false, http_only: false)
        entry = CookieEntry.new(
          name: name.to_s,
          value: value.to_s,
          domain: (domain || "").sub(/\A\./, "").downcase,
          path: path || "/",
          expires: expires,
          secure: secure,
          http_only: http_only,
          host_only: domain.nil?
        )
        @mutex.synchronize { store_entry(entry) }
      end

      # First non-expired cookie value matching the name.
      def get(name)
        @mutex.synchronize { @entries.find { |e| e.name == name.to_s && !expired?(e) }&.value }
      end

      def clear
        @mutex.synchronize { @entries = [] }
      end

      def all
        @mutex.synchronize { @entries.reject { |e| expired?(e) } }
      end

      # Every non-expired cookie as a plain Hash (name/value/domain/path/expires/
      # secure/http_only/host_only) — enough to round-trip the jar to disk and
      # back via #import! without losing host-only scoping. `expires` is a Time or
      # nil; the caller serializes it.
      def export
        all.map(&:to_h)
      end

      # Restore a cookie from an #export Hash, preserving host_only exactly (unlike
      # #set!, which infers it). Skips an already-expired entry. Symbol- or
      # string-keyed Hashes both work, so a JSON round-trip is fine.
      def import!(attrs)
        h = attrs.transform_keys(&:to_sym)
        entry = CookieEntry.new(
          name: h[:name].to_s, value: h[:value].to_s,
          domain: h[:domain].to_s, path: (h[:path] || "/"),
          expires: h[:expires], secure: !!h[:secure],
          http_only: !!h[:http_only], host_only: !!h[:host_only]
        )
        @mutex.synchronize { store_entry(entry) unless expired?(entry) }
        nil
      end

      # Build the Cookie request header value for the given URL, or "".
      def cookies_for(request_url)
        uri = URI.parse(request_url)
        secure_request = uri.scheme == "https"
        host = uri.host.to_s.downcase
        path = uri.path.to_s.empty? ? "/" : uri.path

        matches = @mutex.synchronize do
          @entries.reject { |e| expired?(e) }.select do |e|
            domain_match?(e, host) &&
              path_match?(e.path, path) &&
              (!e.secure || secure_request)
          end
        end

        # More specific (longer) paths first, per RFC 6265 (on the snapshot copy,
        # outside the lock).
        matches.sort_by! { |e| -e.path.length }
        matches.map { |e| "#{e.name}=#{e.value}" }.join("; ")
      end

      private

      def store_entry(entry)
        remove(entry.name, entry.domain, entry.path)
        @entries << entry
      end

      def remove(name, domain, path)
        @entries.reject! { |e| e.name == name && e.domain == domain && e.path == path }
      end

      def parse_set_cookie(string, request_uri)
        segments = string.split(";").map(&:strip)
        name_value = segments.shift.to_s
        return nil unless name_value.include?("=")

        name, value = name_value.split("=", 2)
        name = name.to_s.strip
        return nil if name.empty?

        attrs = parse_attributes(segments)
        request_host = request_uri.host.to_s.downcase

        domain = attrs["domain"]
        host_only = domain.nil? || domain.empty?
        domain = host_only ? request_host : domain.sub(/\A\./, "").downcase

        CookieEntry.new(
          name: name,
          value: value.to_s.strip,
          domain: domain,
          path: attrs["path"] || default_path(request_uri),
          expires: resolve_expiry(attrs),
          secure: attrs.key?("secure"),
          http_only: attrs.key?("httponly"),
          host_only: host_only
        )
      end

      def parse_attributes(segments)
        segments.each_with_object({}) do |segment, acc|
          key, val = segment.split("=", 2)
          acc[key.to_s.strip.downcase] = val&.strip
        end
      end

      # Max-Age takes precedence over Expires.
      def resolve_expiry(attrs)
        if attrs["max-age"]
          seconds = attrs["max-age"].to_i
          Time.now + seconds
        elsif attrs["expires"]
          Time.parse(attrs["expires"]) rescue nil
        end
      end

      # RFC 6265 default-path: directory portion of the request path.
      def default_path(uri)
        path = uri.path.to_s
        return "/" if path.empty? || !path.start_with?("/")

        idx = path.rindex("/")
        idx.nil? || idx.zero? ? "/" : path[0...idx]
      end

      def expired?(entry)
        entry.expires && entry.expires <= Time.now
      end

      def domain_match?(entry, host)
        if entry.host_only
          host == entry.domain
        else
          host == entry.domain || host.end_with?(".#{entry.domain}")
        end
      end

      # RFC 6265 path-match.
      def path_match?(cookie_path, request_path)
        return true if cookie_path == request_path
        return false unless request_path.start_with?(cookie_path)

        cookie_path.end_with?("/") || request_path[cookie_path.length] == "/"
      end
    end
  end
end
