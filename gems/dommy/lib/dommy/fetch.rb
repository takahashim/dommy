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

      delay = entry["delay"]
      if delay
        install_delayed_resolve(promise, body, status, status_text, headers, init, delay)
      else
        promise.fulfill(
          Response.new(@window, body: body, status: status, status_text: status_text, headers: headers, url: url)
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

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[clone].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

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
    def initialize(window, body:, status: 200, status_text: "", headers: nil, url: "")
      @window = window
      @body = body.to_s
      @status = status
      @status_text = status_text.to_s
      @headers = Headers.new(headers || {})
      @url = url.to_s
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
      when "headers"
        @headers
      when "body"
        @body
      end
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[text json arrayBuffer blob clone].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, _args)
      case method
      when "text"
        immediate(@body)
      when "json"
        begin
          immediate(JSON.parse(@body))
        rescue JSON::ParserError => e
          err = ErrorValue.new("JSON parse: #{e.message}")
          rejected(err)
        end

      when "arrayBuffer"
        immediate(@body.bytes)
      when "blob"
        immediate(Blob.new([@body], "type" => @headers.__js_call__("get", ["content-type"]) || ""))
      when "clone"
        Response.new(
          @window,
          body: @body,
          status: @status,
          status_text: @status_text,
          headers: @headers.to_h,
          url: @url
        )
      end
    end

    private

    def immediate(value)
      PromiseValue.resolve(@window, value)
    end

    def rejected(value)
      PromiseValue.reject(@window, value)
    end
  end

  # Minimal `Headers` proxy. Consumer code typically calls
  # `headers.call(:entries)` and iterates via `Array.from(...)`, so
  # we just need `entries` and `get`.
  class Headers
    def initialize(hash)
      @hash = hash.is_a?(Hash) ? hash.transform_keys(&:to_s) : {}
    end

    def to_h
      @hash.dup
    end

    def __js_get__(_key)
      nil
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[get set append delete has keys values entries forEach].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, args)
      case method
      when "set"
        @hash[Headers.canonical(args[0].to_s)] = args[1].to_s
        nil
      when "append"
        # WHATWG: append combines existing values with ", ".
        key = Headers.canonical(args[0].to_s)
        existing = @hash[args[0].to_s] || @hash[key]
        @hash.delete(args[0].to_s)
        @hash[key] = existing ? "#{existing}, #{args[1]}" : args[1].to_s
        nil
      when "delete"
        @hash.delete(args[0].to_s)
        @hash.delete(Headers.canonical(args[0].to_s))
        nil
      when "keys"
        @hash.keys
      when "values"
        @hash.values
      when "get"
        name = args[0].to_s
        @hash[name] || @hash[Headers.canonical(name)]
      when "entries"
        @hash.to_a
      when "has"
        # Match `get`'s case-insensitive lookup: try the raw name
        # first, then the Title-Case canonical form. WHATWG defines
        # header names as case-insensitive throughout the Headers API.
        name = args[0].to_s
        @hash.key?(name) || @hash.key?(Headers.canonical(name))
      when "forEach"
        # WHATWG: forEach(callback) — callback(value, key, headers).
        # Pass `self` as the third argument so consumers that read
        # `(_, _, h) => h.get("Foo")` work the same as in a browser.
        cb = args[0]
        @hash.each do |k, v|
          if cb.respond_to?(:__js_call__)
            cb.__js_call__("call", [v, k, self])
          elsif cb.respond_to?(:call)
            cb.call(v, k, self)
          end
        end

        nil
      end
    end

    def self.canonical(name)
      name.split("-").map(&:capitalize).join("-")
    end
  end
end
