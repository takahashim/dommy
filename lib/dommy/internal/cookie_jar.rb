# frozen_string_literal: true

module Dommy
  module Internal
    # Manages document cookie storage (in-memory, not persisted).
    # Implements the simple document.cookie key=value; key=value interface.
    class CookieJar
      def initialize
        @cookies = {}
      end

      # Return all cookies as "name=value; name=value" string
      def to_cookie_string
        @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
      end

      # Parse and store a cookie from a Set-Cookie-style string
      def set_cookie(value)
        pair = value.to_s.split(";", 2).first.to_s.strip
        return if pair.empty?

        key, val = pair.split("=", 2)
        @cookies[key.to_s.strip] = val.to_s.strip if key
      end
    end
  end
end
