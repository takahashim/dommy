# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "data_uri"

module Dommy
  # `fetch` polyfill. No real network — instead resolves a response
  # *entry* and synthesizes a Response from it. Entries come from, in
  # order:
  #
  #   1. `window.globals["__fetch_handler__"]` — a callable
  #      `call(url, init) -> entry-or-nil`. This is the seam host
  #      environments use to serve real requests (e.g. dommy-rack's
  #      NetworkBridge routes same-origin URLs to the Rack app).
  #      Returning nil falls through to the stub maps.
  #   2. `JS.global[:__fetchy_stub__]` (a Hash{url => entry})
  #      installed by the test. Mirrors the same fixture protocol that
  #      `test_fetchy.rb`'s JavaScript installer uses, so tests don't
  #      need a JS engine to drive the stub.
  #
  # Each entry supports:
  #   "status" / "statusText" / "body" / "contentType" /
  #   "headers" (Hash) / "url" / "redirected" / "delay" (ms)
  # plus AbortController signal propagation when `init[:signal]` is
  # passed.
  class FetchFn
    def initialize(window)
      @window = window
    end

    # JS calls `fetch(url, init)` end up here via either Window-level
    # `__js_call__("fetch", ...)` or as a callable handle. Both routes
    # delegate to `call(args)` so behavior is identical.
    def __js_call__(_method, args)
      # Per Fetch, the request URL is resolved against the document base URL up
      # front; the handler, stub maps, and response.url all see the absolute
      # URL (no per-handler resolution).
      url = @window.__internal_resolve_url__(args[0].to_s)
      init = normalize_init(args[1] || {})

      # `js_eval`'s JS installer increments these globals; mirror so
      # specs that probe `__fetch_count__` / `__last_url__` / etc.
      # observe the same state shape they'd see from a real injector.
      @window.globals["__fetch_count__"] = (@window.globals["__fetch_count__"] || 0).to_i + 1
      @window.globals["__last_url__"] = url
      @window.globals["__last_init__"] = init
      @window.globals["__last_body__"] = init["body"] if init.is_a?(Hash)

      promise = PromiseValue.new(@window)
      result = resolve_entry(url, init)
      # A handler may answer asynchronously (live network off-thread): it returns
      # a deferred whose response arrives later and is applied on the page thread
      # (via the scheduler inbox). The sync path (stubs / cache / data:) resolves
      # the promise inline, exactly as before.
      if result.respond_to?(:on_complete)
        result.on_complete { |entry| fulfill_from_entry(promise, entry, url, init) }
      else
        settle_with_redirects(promise, url, init, result)
      end
      promise
    end

    private

    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
    MAX_REDIRECTS = 20

    # Follow redirects on the SYNCHRONOUS resolve path (endpoints / stubs resolve
    # inline). Honors the request's redirect mode: "follow" chases a 3xx that
    # carries a valid http(s) Location — up to MAX_REDIRECTS, marking the result
    # `redirected` — "manual" yields an opaqueredirect, "error" rejects. A 3xx
    # with no Location, or any non-3xx, is the final response.
    def settle_with_redirects(promise, url, init, entry)
      mode = (init["redirect"] || "follow").to_s
      current = url
      redirected = false
      hops = 0
      loop do
        status = (entry.is_a?(Hash) ? entry["status"] : nil).to_i
        unless REDIRECT_STATUSES.include?(status)
          return fulfill_from_entry(promise, mark_redirected(entry, redirected), current, init)
        end

        case mode
        when "manual" then return deliver_task { promise.fulfill(opaqueredirect_response) }
        when "error" then return deliver_task { promise.reject(fetch_type_error) }
        end

        location = header_value(entry["headers"], "location")
        # A 3xx with no Location is not a redirect to follow — it is the response.
        return fulfill_from_entry(promise, mark_redirected(entry, redirected), current, init) if location.nil?

        hops += 1
        return deliver_task { promise.reject(fetch_type_error) } if hops > MAX_REDIRECTS

        target = redirect_target(current, location)
        return deliver_task { promise.reject(fetch_type_error) } if target.nil?

        current = target
        redirected = true
        init = redirect_init(init, status)
        entry = resolve_entry(current, init)
        if entry.respond_to?(:on_complete)
          captured = current
          captured_init = init
          return entry.on_complete { |e| fulfill_from_entry(promise, mark_redirected(e, true), captured, captured_init) }
        end
      end
    end

    def header_value(headers, name)
      return nil unless headers.is_a?(Hash)

      headers.find { |k, _| k.to_s.casecmp?(name) }&.last
    end

    def mark_redirected(entry, redirected)
      return entry unless redirected && entry.is_a?(Hash)

      entry.merge("redirected" => true)
    end

    # A redirect target resolved against the current URL, or nil when it is not a
    # fetchable http(s) URL — an invalid URL, or a data:/other scheme (following a
    # redirect to those is a network error).
    def redirect_target(current, location)
      # An empty Location value is a network error (not a self-redirect).
      return nil if location.to_s.strip.empty?

      target = URI.join(current, location).to_s
      scheme = URI.parse(target).scheme&.downcase
      %w[http https].include?(scheme) ? target : nil
    rescue URI::Error
      nil
    end

    # Per Fetch: a 303 (and a 301/302 on POST) switches the method to GET and
    # drops the body; 307/308 preserve them.
    def redirect_init(init, status)
      method = (init["method"] || "GET").to_s.upcase
      return init unless status == 303 || ([301, 302].include?(status) && method == "POST")

      init.merge("method" => "GET").tap { |h| h.delete("body") }
    end

    def opaqueredirect_response
      Response.new(@window, body: "", status: 0, status_text: "", headers: {},
        url: "", redirected: false, type: "opaqueredirect", has_body: false)
    end

    # A Bridge::TypeError (not a plain ErrorValue) so the rejection reason crosses
    # as a real JS `TypeError` — `promise_rejects_js`/`assert_throws_js` check
    # `instanceof TypeError`, which a flattened {name,message} object would fail.
    def fetch_type_error
      Bridge::TypeError.new("Failed to fetch")
    end

    # Run work as a networking task on the event loop, matching fulfill_from_entry
    # (so a fetch settles after the initiating script's microtask checkpoint).
    def deliver_task(&blk)
      if (sched = @window.respond_to?(:scheduler) ? @window.scheduler : nil)
        sched.set_timeout(proc(&blk), 0)
      else
        blk.call
      end
      nil
    end

    # Resolve `promise` from a response entry (nil -> 404), honoring a simulated
    # `delay`. Used both for a synchronous entry and for an async one delivered
    # later on the page thread.
    def fulfill_from_entry(promise, entry, url, init)
      # WHATWG: a fetch is resolved by a networking *task*, never inline during
      # the fetch() call — so the initiating script runs to completion and its
      # microtask checkpoint happens first. Defer the fulfillment onto the
      # scheduler as a task so the synchronous data path gets the same event-loop
      # semantics as the async DeferredResponse path. Without a scheduler (rare
      # embedder), fall back to inline.
      if (sched = @window.respond_to?(:scheduler) ? @window.scheduler : nil)
        sched.set_timeout(proc { deliver_entry(promise, entry, url, init) }, 0)
      else
        deliver_entry(promise, entry, url, init)
      end
    end

    def deliver_entry(promise, entry, url, init)
      if entry.nil?
        promise.fulfill(Response.new(@window, body: "not found", status: 404, status_text: "Not Found", type: "basic"))
        return
      end

      body = entry["body"]
      status = (entry["status"] || 200).to_i
      status_text = entry["statusText"] || ""
      content_type = entry["contentType"] || "text/plain"
      headers = entry["headers"] || {"Content-Type" => content_type}
      # Simulate a followed redirect: `[:url]` overrides the response URL (the
      # final location) and `[:redirected]` flags it, so consumers that branch on
      # `response.redirected` / `response.url` (e.g. Turbo updating history to the
      # redirected location) see a realistic response.
      response_url = entry["url"] || url
      redirected = entry["redirected"] ? true : false

      __dommy_dump_fetch__(url, init, status, headers, body) if ENV["DOMMY_FETCH_DEBUG"]

      if (delay = entry["delay"])
        install_delayed_resolve(promise, body, status, status_text, headers, init, delay)
      else
        promise.fulfill(
          Response.new(@window, body: body, status: status, status_text: status_text,
            headers: headers, url: response_url, redirected: redirected, type: "basic")
        )
      end
    end

    # Resolve the response entry for a request: a `__fetch_handler__`
    # callable gets first refusal; a nil from it (or no handler) falls
    # through to the stub maps. Each spec file installs its stub under
    # its own global name — `test_fetchy.rb` uses `__fetchy_stub__`;
    # `test_resource*.rb` use `__resource_fetch_stub__` and
    # `__inject_fetch_stub__`. Checked in order; only one should be set
    # at a time.
    def resolve_entry(url, init)
      if (decoded = DataUri.parse(url))
        return {"body" => decoded[:body], "status" => 200, "statusText" => "OK",
                "contentType" => decoded[:content_type]}
      end

      handler = @window.globals["__fetch_handler__"]
      if handler.respond_to?(:call)
        entry = handler.call(url, init)
        return entry if entry
      end

      stub_map = @window.globals["__fetchy_stub__"] ||
        @window.globals["__resource_fetch_stub__"] ||
        @window.globals["__inject_fetch_stub__"]
      return nil unless stub_map.is_a?(Hash)

      # The URL is now absolute; a stub keyed by a path ("/api") still matches
      # its resolved form ("http://host/api").
      stub_map[url] || stub_map[@window.__internal_url_path__(url)]
    end

    # Coerce `init` into a Hash with string keys so the rest of the
    # pipeline (and the `__last_init__` globals) sees a uniform shape.
    # When the body is a Blob/File, fill in `Content-Type` from the
    # blob's type unless the caller already provided a header for it.
    # A default User-Agent — real browsers always send one; tests assert its
    # presence, not its value.
    USER_AGENT = "Mozilla/5.0 (Dommy)"

    def normalize_init(init)
      h = init.is_a?(Hash) ? init.transform_keys(&:to_s) : {}
      method = (h["method"] || "GET").to_s.upcase
      h["headers"] = request_headers(h["headers"], h["body"], method)
      h
    end

    # The request's header set as a plain Hash (case preserved): the caller's
    # headers (record / sequence of pairs / Headers) plus the defaults a browser
    # adds — Accept, Accept-Language, User-Agent, and, for a body-bearing method,
    # Origin and Content-Length; a Content-Type is derived from an extractable
    # body when the caller set none. So a resolver / endpoint (and the
    # __last_init__ diagnostic) sees the actual request headers. Names are
    # case-insensitive, so a default is added only when absent under any casing.
    def request_headers(raw, body, method)
      headers = normalize_header_record(raw)
      bytes, default_ct = body.nil? ? ["", nil] : Response.extract_body(body)
      headers["Accept"] = "*/*" unless header?(headers, "accept")
      headers["Accept-Language"] = "en-US,en;q=0.9" unless header?(headers, "accept-language")
      headers["User-Agent"] = USER_AGENT unless header?(headers, "user-agent")
      headers["Content-Type"] = default_ct if default_ct && !header?(headers, "content-type")
      # Fetch adds Origin + Content-Length for methods that carry a body (i.e.
      # anything but GET/HEAD); a bodyless such request still sends Content-Length: 0.
      unless %w[GET HEAD].include?(method)
        headers["Origin"] = request_origin unless header?(headers, "origin")
        # Content-Length: the body's byte length; a null body still sends 0, but
        # only for POST/PUT (not arbitrary methods), per Fetch's "extract body".
        unless header?(headers, "content-length")
          if !body.nil?
            headers["Content-Length"] = bytes.bytesize.to_s
          elsif %w[POST PUT].include?(method)
            headers["Content-Length"] = "0"
          end
        end
      end
      headers
    end

    def request_origin
      @window.location.__js_get__("origin").to_s
    rescue StandardError
      ""
    end

    # A header record from a Hash, a sequence of [name, value] pairs, or a
    # Headers, as a plain Hash with string keys (original case preserved).
    def normalize_header_record(raw)
      case raw
      when Headers then raw.to_h
      when Array then raw.each_with_object({}) { |pair, h| h[pair[0].to_s] = pair[1].to_s if pair.is_a?(Array) }
      when Hash then raw.transform_keys(&:to_s)
      else {}
      end
    end

    def header?(headers, name)
      headers.keys.any? { |k| k.to_s.casecmp?(name) }
    end

    # Diagnostic only (DOMMY_FETCH_DEBUG=<file>): append a record of what the
    # page's fetch() received, so a response that an app's data layer can't
    # consume (e.g. Apollo's "link chain completed without emitting a value",
    # #95) can be traced to the actual request/response bytes Dommy handed it.
    # Every fetch is logged compactly; a GraphQL request also dumps full bodies
    # (that is where the emission breaks), which is the exchange we need to see.
    def __dommy_dump_fetch__(url, init, status, headers, body)
      path = ENV["DOMMY_FETCH_DEBUG"]
      graphql = url.include?("graphql")
      req_headers = init.is_a?(Hash) ? init["headers"] : nil
      req_body = init.is_a?(Hash) ? init["body"] : nil
      content_type = headers.is_a?(Hash) ? headers.find { |k, _| k.to_s.downcase == "content-type" }&.last : nil
      method = (init.is_a?(Hash) ? (init["method"] || "GET") : "GET").to_s.upcase
      cap = graphql ? 8000 : 300

      lines = ["=== fetch #{graphql ? "[graphql] " : ""}#{method} #{url}"]
      lines << "> req-headers: #{req_headers.inspect}" if graphql && req_headers
      lines << "> req-body: #{req_body.to_s[0, cap]}" if req_body
      lines << "< #{status} #{content_type} (#{body.to_s.bytesize} bytes)"
      lines << "< res-headers: #{headers.inspect}" if graphql
      lines << "< res-body: #{body.to_s[0, cap]}"
      # `::File` — inside `module Dommy`, bare `File` resolves to Dommy's DOM File.
      ::File.write(path, "#{lines.join("\n")}\n\n", mode: "a")
    rescue StandardError
      nil
    end

    def install_delayed_resolve(promise, body, status, status_text, headers, init, delay_ms)
      # AbortController cancellation: when init.signal is present and
      # `.abort()` fires before the timer, reject with an AbortError.
      # The timer is cleared in that path so it doesn't leak through
      # the test scheduler's drain loop.
      cancelled = [false]
      timer_id = @window.scheduler.set_timeout(
        lambda do |*_args|
          next if cancelled[0]

          promise.fulfill(Response.new(@window, body: body, status: status, status_text: status_text, headers: headers, type: "basic"))
        end,
        delay_ms.to_i
      )
      signal = init.is_a?(Hash) ? init["signal"] : nil
      return unless signal.respond_to?(:__js_call__)

      window_ref = @window
      abort_cb = lambda do |*_args|
        cancelled[0] = true
        window_ref.scheduler.clear_timeout(timer_id)
        err = ErrorValue.new("aborted", name: "AbortError")
        promise.reject(err)
      end

      signal.__js_call__("addEventListener", ["abort", abort_cb])
    end
  end

  # `Request` polyfill — minimal Fetch API Request object so callers
  # constructing `new Request(url, init)` get a value with `.url`,
  # `.method`, `.headers`, `.body`. The stub-based `fetch` doesn't
  # consume it directly (it still takes `(url, init)`), but having
  # Request available means JS code that constructs one before
  # passing to fetch keeps working.
  class Request
    attr_reader :url, :method, :body

    def initialize(url, init = nil, window = nil)
      opts = init.is_a?(Hash) ? init : {}
      @window = window
      @url = url.to_s
      @method = (opts["method"] || opts[:method] || "GET").to_s.upcase
      @body = opts["body"] || opts[:body]
      raw_headers = opts["headers"] || opts[:headers] || {}
      @headers = Headers.new(raw_headers)
      # WHATWG "extract a body": normalize the body source to a byte string once
      # (shared with Response), so the Body consume methods (text/arrayBuffer/…)
      # read from it. A default Content-Type from the extraction is applied only
      # when the caller supplied none.
      unless @body.nil?
        @body_bytes, default_ct = Response.extract_body(@body)
        if default_ct && !@headers.__js_call__("has", ["content-type"])
          @headers.__js_call__("set", ["content-type", default_ct])
        end
      end
      @body_bytes ||= ""
      @credentials = (opts["credentials"] || opts[:credentials] || "same-origin").to_s
      @mode = (opts["mode"] || opts[:mode] || "cors").to_s
      @cache = (opts["cache"] || opts[:cache] || "default").to_s
      @redirect = (opts["redirect"] || opts[:redirect] || "follow").to_s
      # WHATWG: a Request ALWAYS has an associated signal (an AbortSignal). Use a
      # provided signal when present (so `request.signal` is the caller's own
      # controller signal — react-router add/removeEventListener's it directly),
      # else a fresh, never-aborted one. Never undefined, or consumers that read
      # `request.signal.removeEventListener` crash.
      sig = opts["signal"] || opts[:signal]
      @signal = sig.respond_to?(:__js_call__) ? sig : AbortSignal.new
    end

    attr_reader :headers, :credentials, :mode, :cache, :redirect, :signal

    def __js_get__(key)
      case key
      when "url"
        @url
      when "method"
        @method
      when "headers"
        @headers
      when "body"
        @body
      when "credentials"
        @credentials
      when "mode"
        @mode
      when "cache"
        @cache
      when "redirect"
        @redirect
      when "signal"
        @signal
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[clone text json arrayBuffer blob bytes]
    def __js_call__(method, _args)
      case method
      when "clone"
        Request.new(
          @url,
          {
            "method" => @method,
            "body" => @body,
            "headers" => @headers.to_h,
            "credentials" => @credentials,
            "mode" => @mode,
            "cache" => @cache,
            "redirect" => @redirect,
            "signal" => @signal
          },
          @window
        )
      when "text"
        consume_body { immediate(Response.utf8_decode(@body_bytes)) }
      when "json"
        consume_body do
          immediate(JSON.parse(Response.utf8_decode(@body_bytes)))
        rescue JSON::ParserError => e
          rejected(ErrorValue.new("JSON parse: #{e.message}"))
        end
      when "arrayBuffer"
        consume_body { immediate(Bridge::ArrayBuffer.new(@body_bytes.bytes)) }
      when "bytes"
        consume_body { immediate(Bridge::Bytes.new(@body_bytes.bytes)) }
      when "blob"
        ct = @headers.__js_call__("get", ["content-type"]) || ""
        consume_body { immediate(Blob.new([@body_bytes], {"type" => ct}, @window)) }
      end
    end

    private

    # WHATWG Body: the body can be consumed once. A second consume rejects rather
    # than throwing synchronously.
    def consume_body
      if @body_used
        return rejected(ErrorValue.new("Failed to read body: body stream already read", name: "TypeError"))
      end

      @body_used = true
      yield
    end

    def immediate(value)
      @window ? PromiseValue.resolve(@window, value) : value
    end

    def rejected(value)
      @window ? PromiseValue.reject(@window, value) : value
    end
  end

  # `Response` polyfill — just enough surface for Fetchy:
  # `[:status]` / `[:ok]` / `[:url]` / `[:headers]` (with
  # `.entries()` / `.get(name)`) and `.text()` / `.json()` / `.body`
  # / `.arrayBuffer()` which all return Promise-like values.
  class Response
    # WHATWG null-body statuses: a Response with one of these may not carry a
    # body (constructing one with a body is a TypeError). 101/103 are also
    # null-body but fall outside the 200–599 range the constructor accepts.
    NULL_BODY_STATUSES = [204, 205, 304].freeze
    # Redirect statuses accepted by `Response.redirect(url, status)`.
    REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

    # Forbidden response-header names (WHATWG Fetch): never exposed on a
    # Response's Headers. `Set-Cookie` is handled by the network layer's cookie
    # jar, not JS — and a real server often sends MULTIPLE Set-Cookie headers
    # folded into one newline-joined value, which is an invalid Headers value and
    # used to crash Response construction (e.g. doubleclick's IDE+test_cookie).
    FORBIDDEN_RESPONSE_HEADERS = %w[set-cookie set-cookie2].freeze

    def initialize(window, body:, status: 200, status_text: "", headers: nil, url: "",
                   redirected: false, type: "default", has_body: true)
      @window = window
      @body = body.to_s
      @status = status
      @status_text = status_text.to_s
      @headers = Headers.new(strip_forbidden_headers(headers))
      @url = url.to_s
      @redirected = redirected ? true : false
      @type = type
      @has_body = has_body ? true : false
      @body_used = false
      @body_stream = nil
    end

    # Drop forbidden response headers (Set-Cookie/Set-Cookie2) before they reach
    # the Headers object. Only a Hash (the network path) carries them; a Headers
    # or nil passes through unchanged.
    def strip_forbidden_headers(headers)
      return {} if headers.nil?
      return headers unless headers.is_a?(Hash)

      headers.reject { |name, _| FORBIDDEN_RESPONSE_HEADERS.include?(name.to_s.downcase) }
    end

    # WHATWG `new Response(body, init)`. Validates the status (200–599, else a
    # RangeError; a null-body status 204/205/304 with a body is a TypeError),
    # defaults statusText to "" and status to 200, accepts `init.headers` as a
    # plain object or a Headers instance, and — per the body-extraction step —
    # defaults Content-Type to text/plain for a non-null body when none was
    # supplied. A constructed response's url is "".
    def self.__construct__(window, body, init)
      opts = init.is_a?(Hash) ? init : {}
      status = coerce_status(opts["status"] || opts[:status] || 200)
      unless status.between?(200, 599)
        raise Bridge::RangeError,
          "Failed to construct 'Response': The status provided (#{status}) is outside the range [200, 599]."
      end

      has_body = !(body.nil? || (defined?(Bridge::UNDEFINED) && body.equal?(Bridge::UNDEFINED)))
      if has_body && NULL_BODY_STATUSES.include?(status)
        raise Bridge::TypeError,
          "Failed to construct 'Response': Response with null body status (#{status}) cannot have body."
      end

      # Extract a body: derive its bytes and the Content-Type it implies (Blob →
      # its MIME type, URLSearchParams → urlencoded, FormData → multipart, a
      # string → text/plain). The implied type is only the *default* — an
      # explicit init.headers Content-Type still wins.
      body_bytes, default_ct = has_body ? extract_body(body) : ["", nil]

      headers = coerce_headers(opts["headers"] || opts[:headers])
      if default_ct && headers.keys.none? { |k| k.to_s.downcase == "content-type" }
        headers = headers.merge("Content-Type" => default_ct)
      end

      new(window, body: body_bytes,
                  status: status,
                  status_text: validate_status_text!(opts["statusText"] || opts[:statusText] || ""),
                  headers: headers,
                  has_body: has_body)
    end

    # Static `Response.json(data, init)` — serialize `data` to JSON, defaulting
    # Content-Type to application/json. (WHATWG Fetch §Response.json)
    def self.__json__(window, data, init = nil)
      # WHATWG: serialize `data` as JSON; if that yields `undefined` (the value
      # is JS `undefined` — or absent — or otherwise non-serializable), throw a
      # TypeError. JS `null` serializes to "null" and is allowed.
      if defined?(Bridge::UNDEFINED) && data.equal?(Bridge::UNDEFINED)
        raise Bridge::TypeError,
          "Failed to execute 'json' on 'Response': The data is not JSON-serializable."
      end

      opts = init.is_a?(Hash) ? init : {}
      status = coerce_status(opts["status"] || opts[:status] || 200)
      unless status.between?(200, 599)
        raise Bridge::RangeError,
          "Failed to execute 'json' on 'Response': The status provided (#{status}) is outside the range [200, 599]."
      end
      if NULL_BODY_STATUSES.include?(status)
        raise Bridge::TypeError,
          "Failed to execute 'json' on 'Response': Response with null body status (#{status}) cannot have body."
      end

      headers = coerce_headers(opts["headers"] || opts[:headers])
      unless headers.keys.any? { |k| k.to_s.downcase == "content-type" }
        headers = headers.merge("Content-Type" => "application/json")
      end

      new(window, body: JSON.generate(data),
                  status: status,
                  status_text: validate_status_text!(opts["statusText"] || opts[:statusText] || ""),
                  headers: headers)
    end

    # Static `Response.redirect(url, status = 302)` — a redirect response whose
    # `Location` header is the parsed-and-serialized `url`. Parsing failure is a
    # TypeError; a non-redirect status is a RangeError. The url is resolved
    # against the window's base URL so a relative target works. (WHATWG Fetch
    # §Response.redirect)
    def self.__redirect__(window, url, status = nil)
      base = window.respond_to?(:location) && window.location.respond_to?(:href) ? window.location.href : nil
      parsed = Dommy::URL.new(url.to_s, base) # raises Bridge::TypeError on failure

      status = coerce_status(status.nil? || (defined?(Bridge::UNDEFINED) && status.equal?(Bridge::UNDEFINED)) ? 302 : status)
      unless REDIRECT_STATUSES.include?(status)
        raise Bridge::RangeError,
          "Failed to execute 'redirect' on 'Response': Invalid status code #{status}."
      end

      resp = new(window, body: "", status: status, headers: {"Location" => parsed.href}, has_body: false)
      # WHATWG: a redirect response's header guard is "immutable".
      resp.__js_get__("headers").make_immutable!
      resp
    end

    # Static `Response.error()` — a network-error response (status 0, not ok,
    # type "error"). (WHATWG Fetch §Response.error)
    def self.__error__(window)
      resp = new(window, body: "", status: 0, type: "error", has_body: false)
      # WHATWG: a network-error response's header guard is "immutable".
      resp.__js_get__("headers").make_immutable!
      resp
    end

    def self.coerce_status(value)
      value.is_a?(Numeric) ? value.to_i : value.to_s.to_i
    end

    # WHATWG reason-phrase: HTAB / SP / VCHAR (0x21–0x7E) / obs-text (0x80–0xFF).
    # Any other byte (NUL, CR, LF, other controls, DEL) makes statusText invalid
    # → TypeError.
    def self.validate_status_text!(text)
      str = text.to_s
      if str.each_byte.any? { |b| (b < 0x20 && b != 0x09) || b == 0x7f }
        raise Bridge::TypeError, "Failed to construct 'Response': Invalid statusText."
      end
      str
    end

    def self.coerce_headers(raw)
      case raw
      when Headers then raw.to_h
      when Hash then raw
      else {}
      end
    end

    # WHATWG "UTF-8 decode" for a body's text(): interpret the raw bytes as
    # UTF-8, replacing any ill-formed sequence with U+FFFD, and drop a single
    # leading byte-order mark (U+FEFF). Well-formed UTF-8 (the common case) is
    # returned unchanged. Used by both Request and Response text().
    def self.utf8_decode(bytes)
      s = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      s = s.scrub("\u{FFFD}") unless s.valid_encoding?
      s = s[1..] if s.start_with?("\u{FEFF}")
      s
    end

    # WHATWG "extract a body": map a body source to `[byte_string,
    # default_content_type_or_nil]`. The default Content-Type is applied only
    # when the caller supplied none.
    def self.extract_body(body)
      case body
      when Blob # File < Blob
        [body.__dommy_bytes__, (body.type.to_s.empty? ? nil : body.type)]
      when URLSearchParams
        [body.to_s, "application/x-www-form-urlencoded;charset=UTF-8"]
      when FormData
        multipart_body(body)
      when Bridge::Bytes # an ArrayBuffer / TypedArray body
        [body.pack_bytes, nil]
      when String
        [body, "text/plain;charset=UTF-8"]
      else
        if defined?(Bridge::UNDEFINED) && body.equal?(Bridge::UNDEFINED)
          ["", nil]
        else
          [body.to_s, "text/plain;charset=UTF-8"]
        end
      end
    end

    # Serialize a FormData as a multipart/form-data body. Returns `[bytes,
    # content_type]` where content_type carries the generated boundary.
    def self.multipart_body(form_data)
      boundary = "----DommyFormBoundary#{SecureRandom.hex(12)}"
      crlf = "\r\n"
      out = +""
      form_data.entries.each do |name, value|
        out << "--#{boundary}#{crlf}"
        if value.is_a?(Blob)
          filename = value.respond_to?(:name) ? value.name : "blob"
          out << %(Content-Disposition: form-data; name="#{name}"; filename="#{filename}"#{crlf})
          content_type = value.type.to_s.empty? ? "application/octet-stream" : value.type
          out << "Content-Type: #{content_type}#{crlf}#{crlf}"
          out << value.__dommy_bytes__ << crlf
        else
          out << %(Content-Disposition: form-data; name="#{name}"#{crlf}#{crlf})
          out << value.to_s << crlf
        end
      end
      out << "--#{boundary}--#{crlf}"
      [out, "multipart/form-data; boundary=#{boundary}"]
    end

    def __js_get__(key)
      case key
      when "status"
        @status
      when "ok"
        @status >= 200 && @status < 300
      when "statusText"
        @status_text
      when "url"
        @url
      when "redirected"
        # Fetch API: true when the response is the result of a followed
        # redirect (so `response.url` is the final, not requested, URL).
        @redirected
      when "type"
        # WHATWG response type: "default" (constructed), "error" (Response.error),
        # "basic" (a same-origin fetch), …
        @type
      when "headers"
        @headers
      when "body"
        # WHATWG: a ReadableStream of the body bytes, or null when there is no
        # body. Merely reading `.body` does not consume it (identity preserved).
        body_stream
      when "bodyUsed"
        body_used?
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[text json arrayBuffer blob formData clone]
    def __js_call__(method, _args)
      case method
      when "text"
        consume_body { immediate(Response.utf8_decode(@body)) }
      when "json"
        consume_body do
          immediate(JSON.parse(scrub_lone_surrogates(@body)))
        rescue JSON::ParserError => e
          rejected(ErrorValue.new("JSON parse: #{e.message}"))
        end
      when "arrayBuffer"
        # arrayBuffer()'s spec return type is ArrayBuffer — wrap so the host
        # bridge decodes it to a bare JS ArrayBuffer (not a Uint8Array view).
        consume_body { immediate(Bridge::ArrayBuffer.new(@body.bytes)) }
      when "blob"
        consume_body do
          immediate(Blob.new([@body], {"type" => @headers.__js_call__("get", ["content-type"]) || ""}, @window))
        end
      when "formData"
        consume_body { consume_form_data }
      when "clone"
        clone_response
      end
    end

    private

    # WHATWG: the body can be consumed once. `bodyUsed` is true once a consume
    # method ran or the body stream got locked by a reader.
    def body_used?
      @body_used || !!@body_stream&.locked
    end

    # Run a body-consume (text/json/arrayBuffer/blob), rejecting if the body was
    # already used (spec returns a rejected promise, not a synchronous throw).
    def consume_body
      if body_used?
        return rejected(ErrorValue.new("Failed to read body: body stream already read", name: "TypeError"))
      end

      @body_used = true
      yield
    end

    # Lazily build + memoize the body ReadableStream (a single Uint8Array chunk
    # then close), or nil when there is no body.
    def body_stream
      return nil unless @has_body

      @body_stream ||= begin
        stream = ReadableStream.new(@window)
        stream.__internal_enqueue__(Bridge::Bytes.new(@body.bytes)) unless @body.empty?
        stream.__internal_close__
        stream
      end
    end

    # WHATWG: parse the body as a FormData based on Content-Type —
    # application/x-www-form-urlencoded or multipart/form-data. Any other type
    # rejects with a TypeError.
    def consume_form_data
      content_type = (@headers.__js_call__("get", ["content-type"]) || "").to_s
      if content_type.start_with?("application/x-www-form-urlencoded")
        immediate(parse_urlencoded_form(@body))
      elsif (match = content_type.match(/\bmultipart\/form-data\b.*?boundary=("?)([^";]+)\1/i))
        immediate(parse_multipart_form(@body, match[2]))
      else
        rejected(ErrorValue.new("Failed to read body as FormData: unsupported Content-Type", name: "TypeError"))
      end
    end

    def parse_urlencoded_form(body)
      form = FormData.new
      URLSearchParams.new(body).__js_call__("entries", []).each { |name, value| form.append(name, value) }
      form
    end

    # Parse a multipart/form-data body (the inverse of Response.multipart_body):
    # a part with a `filename` becomes a File entry, otherwise a string entry.
    def parse_multipart_form(body, boundary)
      form = FormData.new
      body.split("--#{boundary}").each do |section|
        next if section.empty? || section.start_with?("--") # preamble / closing

        section = section.sub(/\A\r\n/, "")
        head, content = section.split("\r\n\r\n", 2)
        next unless content

        content = content.sub(/\r\n\z/, "")
        disposition = head[/Content-Disposition:\s*form-data;([^\r\n]*)/i, 1].to_s
        name = disposition[/name="([^"]*)"/i, 1]
        next unless name

        filename = disposition[/filename="([^"]*)"/i, 1]
        if filename
          type = head[/Content-Type:\s*([^\r\n]+)/i, 1].to_s.strip
          form.append(name, File.new([content], filename, {"type" => type}, @window))
        else
          form.append(name, content)
        end
      end
      form
    end

    # WHATWG: clone throws if the body is already disturbed/locked; otherwise the
    # clone is an independent Response over the same bytes.
    def clone_response
      if body_used?
        raise Bridge::TypeError, "Failed to execute 'clone' on 'Response': Response body is already used."
      end

      Response.new(
        @window,
        body: @body,
        status: @status,
        status_text: @status_text,
        headers: @headers.to_h,
        url: @url,
        redirected: @redirected,
        type: @type,
        has_body: @has_body
      )
    end

    # A run of one or more adjacent `\uXXXX` JSON escapes.
    SURROGATE_ESCAPE_RUN = /(?:\\u[0-9a-fA-F]{4})+/.freeze

    # Ruby's `JSON.parse` rejects unpaired surrogate escapes (`\uD800` with no
    # trailing low surrogate), and Ruby UTF-8 strings can't hold lone surrogates
    # anyway. The Fetch/URL data corpus uses lone surrogates deliberately; the
    # only meaningful thing to do with them is what the URL parser would do —
    # replace each lone surrogate with U+FFFD. We do that at the escape level
    # (rewriting lone `\uXXXX` surrogate escapes to `�`) so valid pairs are
    # preserved exactly and the parse succeeds.
    def scrub_lone_surrogates(text)
      text.gsub(SURROGATE_ESCAPE_RUN) do |run|
        units = run.scan(/\\u([0-9a-fA-F]{4})/).flatten.map { |h| h.to_i(16) }
        out = +""
        i = 0
        while i < units.length
          u = units[i]
          nxt = units[i + 1]
          if u.between?(0xD800, 0xDBFF) && nxt&.between?(0xDC00, 0xDFFF)
            out << format("\\u%04x\\u%04x", u, nxt)
            i += 2
          elsif u.between?(0xD800, 0xDFFF)
            out << "\\ufffd"
            i += 1
          else
            out << format("\\u%04x", u)
            i += 1
          end
        end
        out
      end
    end

    def immediate(value)
      PromiseValue.resolve(@window, value)
    end

    def rejected(value)
      PromiseValue.reject(@window, value)
    end
  end

  # WHATWG `Headers`. Names are stored lowercased and compared
  # case-insensitively; iteration (`keys`/`values`/`entries`/`forEach`) is
  # sorted by name with duplicate values combined by ", " (the spec's "sort
  # and combine" output). `new Headers(init)` fills from a record (Hash → set
  # per key), a sequence (Array of `[name, value]` pairs → append), or another
  # Headers instance.
  class Headers
    # RFC 7230 token — a valid header name (one or more of these bytes).
    HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/.freeze
    # Leading/trailing HTTP whitespace (tab or space) trimmed from a value.
    HTTP_WHITESPACE = /\A[\t ]+|[\t ]+\z/.freeze

    def initialize(init = nil)
      @list = [] # ordered [lowercased name, value] pairs (duplicates allowed)
      @guard = :none # :none (mutable) or :immutable (Response.error/redirect)
      fill(init)
    end

    # WHATWG: mark these headers immutable — the guard `Response.error()` /
    # `Response.redirect()` give their headers. Any later set/append/delete then
    # raises a TypeError. (Other guards — request/request-no-cors/response
    # forbidden-name filtering — are out of scope: fetch here is stubbed.)
    def make_immutable!
      @guard = :immutable
      self
    end

    # WHATWG "fill": a record (Hash) sets each key; a sequence (Array) appends
    # each [name, value] pair (a non-2-element member is a TypeError); another
    # Headers is copied pair-for-pair.
    def fill(init)
      case init
      when Headers
        init.__internal_raw_pairs__.each { |name, value| append_value(name, value) }
      when Array
        init.each do |pair|
          unless pair.is_a?(Array) && pair.length == 2
            raise Bridge::TypeError,
              "Failed to construct 'Headers': The provided value cannot be converted to a sequence of [name, value] pairs."
          end
          append_value(pair[0], pair[1])
        end
      when Hash
        init.each { |name, value| set_value(name, value) }
      end
      nil
    end

    # Internal: a copy of the raw [name, value] pairs — lets one Headers be
    # filled from another without losing duplicates or split Set-Cookie values.
    def __internal_raw_pairs__
      @list.map(&:dup)
    end

    # A plain Hash of name => combined value (duplicate names combined by ", ";
    # Set-Cookie collapses to its combined value — use getSetCookie for the
    # split list). For callers that want a simple record.
    def to_h
      sort_and_combine.each_with_object({}) do |(name, value), out|
        out[name] = out.key?(name) ? "#{out[name]}, #{value}" : value
      end
    end

    def __js_get__(_key)
      Bridge::ABSENT # Headers exposes only methods; any property read is absent
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[set append delete keys values get entries has forEach getSetCookie]
    def __js_call__(method, args)
      case method
      when "set"
        set_value(args[0], args[1])
        nil
      when "append"
        append_value(args[0], args[1])
        nil
      when "delete"
        ensure_mutable!
        name = validate_name!(args[0])
        @list.reject! { |n, _| n == name }
        nil
      when "get"
        get_combined(validate_name!(args[0]))
      when "has"
        name = validate_name!(args[0])
        @list.any? { |n, _| n == name }
      when "keys"
        sort_and_combine.map(&:first)
      when "values"
        sort_and_combine.map(&:last)
      when "entries"
        sort_and_combine
      when "getSetCookie"
        # WHATWG: Set-Cookie's individual values, in insertion order (never
        # combined, unlike every other header).
        @list.select { |n, _| n == "set-cookie" }.map(&:last)
      when "forEach"
        # WHATWG: forEach(callback) — callback(value, key, headers), in the
        # sort-and-combine order. `self` is the third argument so
        # `(_, _, h) => h.get(...)` works the same as in a browser.
        cb = args[0]
        sort_and_combine.each do |k, v|
          if cb.respond_to?(:__js_call__)
            cb.__js_call__("call", [v, k, self])
          elsif cb.respond_to?(:call)
            cb.call(v, k, self)
          end
        end
        nil
      end
    end

    # RFC 7230 Title-Case form of a header name. Retained as a public helper;
    # the Headers store itself is lowercased per the WHATWG spec.
    def self.canonical(name)
      name.split("-").map(&:capitalize).join("-")
    end

    private

    def set_value(name, value)
      ensure_mutable!
      key = validate_name!(name)
      val = validate_value!(value)
      @list.reject! { |n, _| n == key }
      @list << [key, val]
    end

    def append_value(name, value)
      ensure_mutable!
      @list << [validate_name!(name), validate_value!(value)]
    end

    def ensure_mutable!
      return unless @guard == :immutable

      raise Bridge::TypeError, "Failed to execute on 'Headers': These headers are immutable."
    end

    # WHATWG: a header name must be a token, else a TypeError. Returns it
    # lowercased (the form names are stored and compared in).
    def validate_name!(name)
      str = name.to_s
      unless str.match?(HEADER_NAME)
        raise Bridge::TypeError, "Failed to execute on 'Headers': '#{str}' is an invalid header name."
      end
      str.downcase
    end

    # WHATWG: trim leading/trailing HTTP whitespace, then reject a value
    # containing NUL/CR/LF with a TypeError.
    def validate_value!(value)
      val = value.to_s.gsub(HTTP_WHITESPACE, "")
      if val.match?(/[\x00\r\n]/)
        raise Bridge::TypeError, "Failed to execute on 'Headers': '#{val}' is an invalid header value."
      end
      val
    end

    def get_combined(name)
      values = @list.select { |n, _| n == name }.map(&:last)
      values.empty? ? nil : values.join(", ")
    end

    # WHATWG "sort and combine": unique names sorted ascending; each name's
    # values combined by ", ", except Set-Cookie whose values stay separate.
    def sort_and_combine
      @list.map(&:first).uniq.sort.flat_map do |name|
        if name == "set-cookie"
          @list.select { |n, _| n == "set-cookie" }.map { |n, v| [n, v] }
        else
          [[name, get_combined(name)]]
        end
      end
    end
  end
end
