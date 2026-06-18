# frozen_string_literal: true

module Dommy
  module Rack
    # The persistent request headers a Session sends on every request, plus the
    # auth conveniences that set them. Encapsulates the header state and the
    # case-insensitive merge the way CookieJar encapsulates cookie state — a
    # Session owns one HeaderStore and mutates it via set / delete / basic_auth
    # / bearer.
    #
    # HTTP header names are case-insensitive, so #delete and #merge match names
    # case-insensitively: a per-request override replaces a stored default even
    # when the two names differ only in case.
    class HeaderStore
      def initialize
        @headers = {}
      end

      # A copy of the stored headers. Mutate via #set / #delete.
      def to_h = @headers.dup

      # A detached HeaderStore with the same headers, safe to hand to a network
      # worker thread: it owns its own state (no shared mutation with the page's
      # store) and keeps the case-insensitive #merge a plain Hash would lose.
      def snapshot
        copy = HeaderStore.new
        @headers.each { |name, value| copy.set(name, value) }
        copy
      end

      def set(name, value)
        @headers[name.to_s] = value.to_s
        self
      end

      def delete(name)
        target = name.to_s.downcase
        @headers.delete_if { |key, _| key.downcase == target }
        self
      end

      # The headers to send for one request: the stored defaults with the
      # per-request `override` applied on top. An override wins even if its name
      # differs only in case from a default.
      def merge(override)
        return @headers.dup if override.nil? || override.empty?

        merged = @headers.dup
        override.each do |name, value|
          merged.delete_if { |existing, _| existing.to_s.downcase == name.to_s.downcase }
          merged[name] = value
        end
        merged
      end

      # HTTP Basic auth: sets a persistent Authorization header.
      def basic_auth(user, password)
        set("Authorization", "Basic #{["#{user}:#{password}"].pack("m0")}")
      end

      # Bearer-token auth: sets a persistent Authorization header.
      def bearer(token)
        set("Authorization", "Bearer #{token}")
      end
    end
  end
end
