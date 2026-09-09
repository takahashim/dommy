# frozen_string_literal: true

module Dommy
  module Rack
    # One HTTP request against the Rack app: build the env, call the app, wrap the
    # Response, and store its Set-Cookie headers in the jar. This is the request
    # primitive the redirect loop (Navigation) issues per hop.
    #
    # It deliberately touches only thread-safe / immutable collaborators — the
    # frozen Config, a stateless app, the thread-safe CookieJar, and a header
    # source that is either read-only or a captured snapshot — so the very same
    # exchange can run on a network worker thread, off the page (JS) thread, for
    # the async-network path. The page-thread-only concerns it must NOT own are
    # injected as hooks:
    #
    # * `on_request`  — observe the outgoing env (the synchronous page path records
    #   it as `last_request` and fires request listeners; an async path routes the
    #   same notification through the scheduler inbox).
    # * `on_response` — observe the Response (response listeners).
    # * `on_abort`    — observe an env whose `@app.call` raised (no Response).
    # * `on_app_start` / `on_app_finish` — bracket the app call ITSELF. Unlike
    #   the observation hooks above (which an async path routes through the
    #   scheduler inbox, i.e. LATER and on the page thread), these run inline,
    #   on whatever thread calls the app, so per-request state a hook installs
    #   for the app to find — the Trace's thread-local — is live exactly while
    #   the app runs. Anything they need to hand back travels on the env.
    #
    # Reload bookkeeping (`last_request_args`) and history/document application are
    # NOT here: they belong to the page thread and stay in Session / Navigation.
    class HttpExchange
      # @param headers [HeaderStore, Hash] anything responding to `merge(overrides)
      #   -> Hash`; the Session passes its live HeaderStore for the page path, a
      #   plain snapshot Hash for a worker path.
      def initialize(app:, config:, cookie_jar:, headers:, on_request: nil, on_response: nil, on_abort: nil,
        on_app_start: nil, on_app_finish: nil)
        @app = app
        @config = config
        @cookie_jar = cookie_jar
        @headers = headers
        @on_request = on_request
        @on_response = on_response
        @on_abort = on_abort
        @on_app_start = on_app_start
        @on_app_finish = on_app_finish
      end

      # Perform one request and return its Response. `headers` are per-request
      # overrides merged over the persistent header source.
      def request(method, absolute_url, params: nil, body: nil, headers: {})
        env = RequestBuilder.new(@config).build(
          method: method,
          url: absolute_url,
          params: params,
          body: body,
          headers: @headers.merge(headers),
          cookie_string: @cookie_jar.cookies_for(absolute_url)
        )
        @on_request&.call(env)
        # on_app_start opened a request bracket (the Trace exposes itself
        # thread-locally inside it); an app exception must still close it, or
        # per-request state leaks past the failed request. Close it BEFORE
        # on_abort, which reads what the bracket left on the env. The exception
        # itself propagates unchanged.
        @on_app_start&.call(env)
        begin
          status, response_headers, response_body = @app.call(env)
        rescue ::Exception # rubocop:disable Lint/RescueException -- close the bracket for ANY abort
          @on_app_finish&.call(env)
          @on_abort&.call(env)
          raise
        end
        @on_app_finish&.call(env)
        response = Response.new(status, response_headers, response_body, url: absolute_url)
        response.set_cookie_strings.each do |sc|
          @cookie_jar.store_from_header(sc, absolute_url)
        end
        @on_response&.call(response)
        response
      end
    end
  end
end
