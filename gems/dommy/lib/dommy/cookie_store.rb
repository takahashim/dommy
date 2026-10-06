# frozen_string_literal: true

module Dommy
  # `cookieStore` — the asynchronous Cookie Store API, over the same cookie
  # jar as `document.cookie` (the window's Dommy::CookieJar), for the
  # document's URL and as a "non-HTTP" API: an HttpOnly cookie is neither
  # read nor overwritten. A cookie it sets is Secure, Path=/ and
  # SameSite=Strict unless told otherwise.
  #
  # Spec: https://cookiestore.spec.whatwg.org/
  class CookieStore
    include EventTarget

    def initialize(window)
      @window = window
    end

    def get(name_or_options = nil)
      name, url = query_of(name_or_options)
      found = cookies_for(url).find { |c| name.nil? || c.name == name }
      PromiseValue.resolve(@window, found && build_record(found))
    rescue Bridge::TypeError => e
      PromiseValue.reject(@window, e)
    end

    def get_all(name_or_options = nil)
      name, url = query_of(name_or_options)
      records = cookies_for(url).select { |c| name.nil? || c.name == name }.map { |c| build_record(c) }
      PromiseValue.resolve(@window, records)
    rescue Bridge::TypeError => e
      PromiseValue.reject(@window, e)
    end

    alias getAll get_all

    def set(name_or_options, value = nil)
      opts = name_or_options.is_a?(Hash) ? name_or_options.transform_keys(&:to_s) : {"name" => name_or_options, "value" => value}
      cookie = write(opts)
      dispatch_event(CookieChangeEvent.new("change", "changed" => [build_record(cookie)], "deleted" => []))
      PromiseValue.resolve(@window, nil)
    rescue Bridge::TypeError => e
      PromiseValue.reject(@window, e)
    end

    def delete(name_or_options)
      opts = name_or_options.is_a?(Hash) ? name_or_options.transform_keys(&:to_s) : {"name" => name_or_options}
      write(opts.merge("value" => "", "expires" => 0))
      dispatch_event(CookieChangeEvent.new("change", "changed" => [], "deleted" => [{"name" => opts["name"].to_s, "value" => nil}]))
      PromiseValue.resolve(@window, nil)
    rescue Bridge::TypeError => e
      PromiseValue.reject(@window, e)
    end

    include Bridge::Methods
    js_methods %w[get getAll set delete addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "get"
        get(args[0])
      when "getAll"
        get_all(args[0])
      when "set"
        set(args[0], args[1])
      when "delete"
        delete(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end

    private

    def document_url = @window.document.url

    # The name a query asks for (nil: any) and the URL it is for — the
    # document's, or one with the same origin.
    def query_of(arg)
      return [nil, document_url] if arg.nil?
      return [arg.to_s, document_url] unless arg.is_a?(Hash)

      opts = arg.transform_keys(&:to_s)
      url = document_url
      if opts["url"]
        parsed = @window.__internal_parse_url__(opts["url"].to_s)
        raise Bridge::TypeError, "invalid url" unless parsed && Internal::Origin.of_url(parsed) == @window.origin

        url = parsed
      end
      [opts["name"]&.to_s, url]
    end

    def cookies_for(url)
      return [] if @window.document.__internal_cookie_averse__?

      @window.cookie_jar.matching(url, http: false)
    end

    # "Set a cookie" with the store's defaults, through the jar's storage
    # model; a cookie it refuses is a TypeError.
    def write(opts)
      name = opts["name"].to_s
      value = opts["value"].to_s
      if (name + value).match?(Dommy::CookieJar::CONTROL_CHARACTERS) || name.include?("=") || name.include?(";") || value.include?(";")
        raise Bridge::TypeError, "invalid cookie name or value"
      end
      raise Bridge::TypeError, "a nameless cookie's value cannot contain '='" if name.empty? && value.include?("=")

      parts = ["#{name}=#{value}"]
      domain = opts["domain"]
      if domain
        raise Bridge::TypeError, "domain must not start with '.'" if domain.to_s.start_with?(".")

        parts << "Domain=#{domain}"
      end
      path = (opts["path"] || "/").to_s
      raise Bridge::TypeError, "path must start with '/'" unless path.start_with?("/")

      parts << "Path=#{path}"
      if opts.key?("expires") && !opts["expires"].nil?
        parts << "Expires=#{Time.at(opts["expires"].to_f / 1000).utc.httpdate}"
      end
      parts << "SameSite=#{(opts["sameSite"] || "strict").to_s.capitalize}"
      parts << "Secure"
      cookie = @window.document.__internal_cookie_averse__? ? nil : @window.cookie_jar.store(parts.join("; "), document_url, http: false)
      raise Bridge::TypeError, "the cookie was refused" unless cookie || opts["value"] == "" && opts["expires"] == 0

      cookie || Dommy::CookieJar::Cookie.new(name: name, value: value, path: path)
    end

    def build_record(cookie)
      {
        "name" => cookie.name.to_s,
        "value" => cookie.value.to_s,
        "domain" => cookie.host_only ? nil : cookie.domain,
        "path" => cookie.path || "/",
        "expires" => cookie.expires ? (cookie.expires.to_f * 1000).round : nil,
        "secure" => cookie.secure ? true : false,
        "sameSite" => (cookie.same_site || "Default").to_s.downcase.then { |v| v == "default" ? "lax" : v },
        "partitioned" => false
      }
    end
  end

  class CookieChangeEvent < Event
    def initialize(type, init = nil)
      super
      @changed = Array(read_init(init, "changed") || [])
      @deleted = Array(read_init(init, "deleted") || [])
    end

    attr_reader :changed, :deleted

    def __js_get__(key)
      case key
      when "changed"
        @changed
      when "deleted"
        @deleted
      else
        super
      end
    end
  end
end
