# frozen_string_literal: true

module Dommy
  module Rack
    # The session's cookie store: Dommy::CookieJar (RFC 6265bis storage and
    # retrieval), shared by the requests the session sends to the app and by
    # its pages' `document.cookie` / `cookieStore`, under the names this gem
    # has always used. Thread-safe (network workers store and read too).
    class CookieJar < Dommy::CookieJar
      CookieEntry = Dommy::CookieJar::Cookie

      # Store a response's Set-Cookie header value, received from `request_url`.
      def store_from_header(set_cookie_string, request_url)
        store(set_cookie_string, request_url, http: true)
        nil
      end

      # The Cookie request header value for `request_url`, or "".
      def cookies_for(request_url) = cookie_string(request_url, http: true)
    end
  end
end
