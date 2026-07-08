# frozen_string_literal: true

require "uri"

module Dommy
  module Rack
    # URL resolution, redirect following, same-origin enforcement, and
    # browser-tab-style history. Reads policy from the frozen Config and drives
    # the Session only through its request seam (raw_request /
    # apply_navigation_response / current_url).
    class Navigation
      KEEP_METHOD_STATUSES = [307, 308].freeze
      # Verbs whose params belong in the URL query (vs a request body).
      QUERY_METHODS = %w[GET HEAD].freeze

      def initialize(session, config)
        @session = session
        @config = config
      end

      # Resolve a possibly-relative URL against a base (current URL or host).
      def resolve_url(url_or_path, base_url)
        base = base_url || @config.default_host
        # A link/redirect target may carry raw UTF-8 (e.g. /hashtag/応援); the
        # ASCII-only URI parser needs it percent-encoded first (what a browser
        # does), or URI.join raises and the rescue would leak a non-ASCII URL
        # that crashes downstream (cookie matching, request building).
        URI.join(base, Url.encode_iri(url_or_path)).to_s
      rescue URI::InvalidURIError
        url_or_path.to_s
      end

      # Merge ordered [name, value] params into `url`'s query, preserving any
      # existing query and keeping a fragment last (browser address-bar form).
      def append_query(url, params)
        encoded = URI.encode_www_form(params)
        return url if encoded.empty?

        base, hash, fragment = url.to_s.partition("#")
        sep = base.include?("?") ? "&" : "?"
        "#{base}#{sep}#{encoded}#{hash}#{fragment}"
      end

      def check_same_origin!(url)
        return unless @config.enforce_same_origin
        return if same_origin?(url, @config.default_host)

        raise CrossOriginError, "cross-origin request to #{url} is not allowed"
      end

      # Perform a navigation, following redirects per session policy, then
      # apply the final response to the session (updating document + history).
      def navigate(method:, url:, params: nil, body: nil, headers: {}, replace: false)
        return navigate_about(url.to_s) if url.to_s.start_with?("about:")

        verb = method.to_s.upcase
        target = resolve_url(url, @session.current_url)
        # A GET-style navigation carries its data in the URL: fold params into the
        # query so current_url (the address the user sees, and reloads) reflects
        # what was submitted — exactly what a browser shows after a GET form. POST
        # keeps params as the request body. (params and body are mutually
        # exclusive, so a GET never has a body to conflict with.)
        if params && QUERY_METHODS.include?(verb)
          target = append_query(target, params)
          params = nil
        end
        check_same_origin!(target)

        response, final_url = run(method: verb, url: target, params: params, body: body, headers: headers)
        # replace: a location.replace() / reload() / redirect updates the current
        # history entry in place rather than pushing a new one.
        @session.apply_navigation_response(response, final_url, replace: replace)
        maybe_follow_meta_refresh(response) || response
      end

      # Fetch-style request: resolves and enforces origin, runs the redirect
      # loop per mode, and returns the Response without touching session state.
      def fetch(url, method: "GET", params: nil, body: nil, headers: {}, redirect: :follow)
        verb = method.to_s.upcase
        target = resolve_url(url, @session.current_url)
        check_same_origin!(target)
        run_fetch(verb, target, params: params, body: body, headers: headers, redirect: redirect)
      end

      # Worker-safe variant of #fetch: `target` is already absolute and origin-
      # checked (the page thread did both before handing off), and every request
      # in the redirect loop is issued through `exchange` (which touches only
      # thread-safe state) instead of the session. Returns the Response. This is
      # the primitive a network worker runs for the async-network path.
      def fetch_resolved(exchange, method, target, params: nil, body: nil, headers: {}, redirect: :follow)
        run_fetch(method.to_s.upcase, target, params: params, body: body, headers: headers,
                  redirect: redirect, exchange: exchange)
      end

      # Re-navigate to an already-resolved URL without pushing a new history
      # entry (used by Session#back / #forward).
      def revisit(url)
        response, final_url = run(method: "GET", url: url)
        @session.apply_navigation_response(response, final_url, push_history: false)
        response
      end

      # Run the request/redirect loop. Returns [response, final_url].
      # Public so Session#fetch can reuse it without applying navigation state.
      def run(method:, url:, params: nil, body: nil, headers: {}, follow: true, exchange: nil)
        verb = method
        target = url
        # Carry the fragment across redirects: a redirect Location without its
        # own fragment preserves the previous one (browser behavior).
        fragment = uri_fragment(target)
        redirect_count = 0
        chain = []

        loop do
          # Default path issues through the session (page thread). When an
          # `exchange` is injected, the very same loop runs on a network worker.
          response =
            if exchange
              exchange.request(verb, target, params: params, body: body, headers: headers)
            else
              @session.raw_request(verb, target, params: params, body: body, headers: headers)
            end

          unless follow && redirect_to_follow?(response)
            response.redirects = chain
            return [response, with_fragment(target, fragment)]
          end

          chain << {status: response.status, url: target, location: response.location_header}
          redirect_count += 1
          if redirect_count > @config.max_redirects
            raise TooManyRedirectsError, "exceeded #{@config.max_redirects} redirects"
          end

          target = resolve_url(response.location_header, target)
          check_same_origin!(target)
          location_fragment = uri_fragment(target)
          fragment = location_fragment unless location_fragment.nil? || location_fragment.empty?

          unless KEEP_METHOD_STATUSES.include?(response.status)
            params = nil
            body = nil
          end
          verb = redirect_method(response.status, verb)
        end
      end

      private

      # Run the redirect loop per fetch `redirect` mode and return the Response.
      # Shared by the page-thread #fetch and the worker-safe #fetch_resolved
      # (which passes an `exchange`); the only difference is where requests issue.
      def run_fetch(verb, target, params:, body:, headers:, redirect:, exchange: nil)
        args = {method: verb, url: target, params: params, body: body, headers: headers, exchange: exchange}
        case redirect
        when :follow
          run(**args, follow: true).first
        when :manual
          run(**args, follow: false).first
        when :error
          response = run(**args, follow: false).first
          raise Error, "redirect encountered with redirect: :error" if response.redirect?

          response
        else
          raise ArgumentError, "unsupported redirect mode: #{redirect.inspect}"
        end
      end

      # `about:` URLs never hit the app: install a blank document (a browser's
      # about:blank) and record the URL as-is in current_url and history.
      def navigate_about(url)
        response = Response.new(
          200, {"Content-Type" => "text/html"},
          ["<html><head></head><body></body></html>"], url: url
        )
        @session.apply_navigation_response(response, url)
        response
      end

      # If the just-applied response asks for an immediate meta refresh,
      # navigate there (browser behavior). Returns the final response after any
      # chain of refreshes, or nil if none applied. Detecting the refresh is
      # the Response's job; this only performs the navigation.
      def maybe_follow_meta_refresh(response, depth = 0)
        return nil unless @config.follow_meta_refresh

        url = response.meta_refresh_url
        return nil unless url

        if depth >= @config.max_redirects
          raise TooManyRedirectsError, "exceeded #{@config.max_redirects} meta refreshes"
        end

        target = resolve_url(url, @session.current_url)
        check_same_origin!(target)
        next_response, final_url = run(method: "GET", url: target)
        @session.apply_navigation_response(next_response, final_url)
        maybe_follow_meta_refresh(next_response, depth + 1) || next_response
      end

      def uri_fragment(url)
        URI.parse(url.to_s).fragment
      rescue URI::InvalidURIError
        nil
      end

      def with_fragment(url, fragment)
        return url if fragment.nil? || fragment.empty?
        return url unless uri_fragment(url).to_s.empty?

        "#{url}##{fragment}"
      end

      def redirect_to_follow?(response)
        response.redirect? &&
          @config.follow_redirects &&
          !response.location_header.to_s.empty?
      end

      def redirect_method(status, original)
        case status
        when 303 then "GET"
        when 301, 302 then original == "POST" ? "GET" : original
        else original # 307, 308 keep the method
        end
      end

      def same_origin?(url_a, url_b)
        a = URI.parse(url_a)
        b = URI.parse(url_b)
        a.scheme == b.scheme && a.host == b.host && a.port == b.port
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
