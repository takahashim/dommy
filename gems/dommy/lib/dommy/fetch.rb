# frozen_string_literal: true

require "json"

module Dommy
  # `fetch` polyfill. No real network — instead consults
  # `JS.global[:__fetchy_stub__]` (a Hash{url => entry}) installed by
  # the test. Mirrors the same fixture protocol that `test_fetchy.rb`'s
  # JavaScript installer uses, so tests don't need a JS engine to drive
  # the stub.
  #
  # Each entry in the stub hash supports:
  #   "status" / "statusText" / "body" / "contentType" /
  #   "headers" (Hash) / "delay" (ms)
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
      url = args[0].to_s
      init = normalize_init(args[1] || {})

      # Each spec file installs its stub under its own global name.
      # `test_fetchy.rb` uses `__fetchy_stub__`; `test_resource*.rb`
      # use `__resource_fetch_stub__` and `__inject_fetch_stub__`.
      # Check them in order — only one should be set at a time.
      stub_map = @window.globals["__fetchy_stub__"] ||
        @window.globals["__resource_fetch_stub__"] ||
        @window.globals["__inject_fetch_stub__"] ||
        {}
      # `js_eval`'s JS installer increments these globals; mirror so
      # specs that probe `__fetch_count__` / `__last_url__` / etc.
      # observe the same state shape they'd see from a real injector.
      @window.globals["__fetch_count__"] = (@window.globals["__fetch_count__"] || 0).to_i + 1
      @window.globals["__last_url__"] = url
      @window.globals["__last_init__"] = init
      @window.globals["__last_body__"] = init["body"] if init.is_a?(Hash)

      entry = stub_map[url] if stub_map.is_a?(Hash)
      promise = PromiseValue.new(@window)

      if entry.nil?
        response = Response.new(@window, body: "not found", status: 404, status_text: "Not Found")
        promise.fulfill(response)
        return promise
      end

      body = entry["body"]
      status = (entry["status"] || 200).to_i
      status_text = entry["statusText"] || ""
      content_type = entry["contentType"] || "text/plain"
      headers = entry["headers"] || {"Content-Type" => content_type}
      # Simulate a followed redirect: `[:url]` overrides the response URL (the
      # final location) and `[:redirected]` flags it, so consumers that branch
      # on `response.redirected` / `response.url` (e.g. Turbo updating history to
      # the redirected location) see a realistic response.
      response_url = entry["url"] || url
      redirected = entry["redirected"] ? true : false

      delay = entry["delay"]
      if delay
        install_delayed_resolve(promise, body, status, status_text, headers, init, delay)
      else
        promise.fulfill(
          Response.new(@window, body: body, status: status, status_text: status_text,
            headers: headers, url: response_url, redirected: redirected)
        )
      end

      promise
    end

    private

    # Coerce `init` into a Hash with string keys so the rest of the
    # pipeline (and the `__last_init__` globals) sees a uniform shape.
    # When the body is a Blob/File, fill in `Content-Type` from the
    # blob's type unless the caller already provided a header for it.
    def normalize_init(init)
      return init unless init.is_a?(Hash)

      h = init.transform_keys(&:to_s)
      body = h["body"]
      return h unless body.is_a?(Blob)

      headers = (h["headers"] || {}).dup
      content_type_set = headers.any? { |k, _| k.to_s.downcase == "content-type" }
      headers["Content-Type"] = body.type if !content_type_set && !body.type.empty?
      h["headers"] = headers
      h
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

          promise.fulfill(Response.new(@window, body: body, status: status, status_text: status_text, headers: headers))
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

    def initialize(url, init = nil)
      opts = init.is_a?(Hash) ? init : {}
      @url = url.to_s
      @method = (opts["method"] || opts[:method] || "GET").to_s.upcase
      @body = opts["body"] || opts[:body]
      raw_headers = opts["headers"] || opts[:headers] || {}
      @headers = Headers.new(raw_headers)
      @credentials = (opts["credentials"] || opts[:credentials] || "same-origin").to_s
      @mode = (opts["mode"] || opts[:mode] || "cors").to_s
      @cache = (opts["cache"] || opts[:cache] || "default").to_s
      @redirect = (opts["redirect"] || opts[:redirect] || "follow").to_s
    end

    attr_reader :headers, :credentials, :mode, :cache, :redirect

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
      end
    end

    include Bridge::Methods
    js_methods %w[clone]
    def __js_call__(method, _args)
      case method
      when "clone"
        Request.new(
          @url,
          "method" => @method,
          "body" => @body,
          "headers" => @headers.to_h,
          "credentials" => @credentials,
          "mode" => @mode,
          "cache" => @cache,
          "redirect" => @redirect
        )
      end
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

    def initialize(window, body:, status: 200, status_text: "", headers: nil, url: "", redirected: false)
      @window = window
      @body = body.to_s
      @status = status
      @status_text = status_text.to_s
      @headers = Headers.new(headers || {})
      @url = url.to_s
      @redirected = redirected ? true : false
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

      headers = coerce_headers(opts["headers"] || opts[:headers])
      if has_body && headers.keys.none? { |k| k.to_s.downcase == "content-type" }
        headers = headers.merge("Content-Type" => "text/plain;charset=UTF-8")
      end

      new(window, body: has_body ? body : "",
                  status: status,
                  status_text: (opts["statusText"] || opts[:statusText] || "").to_s,
                  headers: headers)
    end

    # Static `Response.json(data, init)` — serialize `data` to JSON, defaulting
    # Content-Type to application/json. (WHATWG Fetch §Response.json)
    def self.__json__(window, data, init = nil)
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
                  status_text: (opts["statusText"] || opts[:statusText] || "").to_s,
                  headers: headers)
    end

    # Static `Response.redirect(url, status = 302)` — a redirect response whose
    # `Location` header is `url`; `status` must be a redirect status, else a
    # RangeError. (WHATWG Fetch §Response.redirect)
    def self.__redirect__(window, url, status = nil)
      status = coerce_status(status.nil? || (defined?(Bridge::UNDEFINED) && status.equal?(Bridge::UNDEFINED)) ? 302 : status)
      unless REDIRECT_STATUSES.include?(status)
        raise Bridge::RangeError,
          "Failed to execute 'redirect' on 'Response': Invalid status code #{status}."
      end

      new(window, body: "", status: status, headers: {"Location" => url.to_s})
    end

    # Static `Response.error()` — a network-error response (status 0, not ok).
    # (WHATWG Fetch §Response.error)
    def self.__error__(window)
      new(window, body: "", status: 0)
    end

    def self.coerce_status(value)
      value.is_a?(Numeric) ? value.to_i : value.to_s.to_i
    end

    def self.coerce_headers(raw)
      case raw
      when Headers then raw.to_h
      when Hash then raw
      else {}
      end
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
      when "headers"
        @headers
      when "body"
        @body
      end
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[text json arrayBuffer blob clone]
    def __js_call__(method, _args)
      case method
      when "text"
        immediate(@body)
      when "json"
        begin
          immediate(JSON.parse(scrub_lone_surrogates(@body)))
        rescue JSON::ParserError => e
          err = ErrorValue.new("JSON parse: #{e.message}")
          rejected(err)
        end

      when "arrayBuffer"
        # Wrap in Bridge::Bytes so the host bridge decodes it to a real JS
        # ArrayBuffer/typed array (a plain Array would cross as a JS array).
        immediate(Bridge::Bytes.new(@body.bytes))
      when "blob"
        immediate(Blob.new([@body], "type" => @headers.__js_call__("get", ["content-type"]) || ""))
      when "clone"
        Response.new(
          @window,
          body: @body,
          status: @status,
          status_text: @status_text,
          headers: @headers.to_h,
          url: @url,
          redirected: @redirected
        )
      end
    end

    private

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
    def initialize(init = nil)
      @hash = {} # lowercased name => combined value
      fill(init)
    end

    # WHATWG "fill" — a sequence appends each pair; a record sets each key.
    def fill(init)
      case init
      when Headers
        init.to_h.each { |name, value| append_value(name, value) }
      when Array
        init.each { |pair| append_value(pair[0], pair[1]) if pair.is_a?(Array) }
      when Hash
        init.each { |name, value| set_value(name, value) }
      end
      nil
    end

    # A plain Hash of the (already lowercased) stored headers.
    def to_h
      @hash.dup
    end

    def __js_get__(_key)
      nil
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
        @hash.delete(args[0].to_s.downcase)
        nil
      when "get"
        @hash[args[0].to_s.downcase]
      when "has"
        @hash.key?(args[0].to_s.downcase)
      when "keys"
        sorted_keys
      when "values"
        sorted_keys.map { |k| @hash[k] }
      when "entries"
        sorted_keys.map { |k| [k, @hash[k]] }
      when "getSetCookie"
        # WHATWG: the Set-Cookie values as a list (uncombined). We store a
        # single combined value, so return it as a one-element list when set.
        @hash.key?("set-cookie") ? [@hash["set-cookie"]] : []
      when "forEach"
        # WHATWG: forEach(callback) — callback(value, key, headers), in sorted
        # order. Pass `self` as the third argument so `(_, _, h) => h.get(...)`
        # works the same as in a browser.
        cb = args[0]
        sorted_keys.each do |k|
          v = @hash[k]
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
      @hash[name.to_s.downcase] = value.to_s
    end

    def append_value(name, value)
      key = name.to_s.downcase
      @hash[key] = @hash.key?(key) ? "#{@hash[key]}, #{value}" : value.to_s
    end

    def sorted_keys
      @hash.keys.sort
    end
  end
end
