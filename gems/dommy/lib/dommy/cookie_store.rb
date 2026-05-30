# frozen_string_literal: true

module Dommy
  # `cookieStore` — the asynchronous Cookie Store API. Reads and
  # writes go through the existing `Document#cookie_jar`, so values
  # set via `document.cookie = ...` round-trip via `cookieStore.get`.
  #
  # Spec: https://wicg.github.io/cookie-store/
  class CookieStore
    include EventTarget

    def initialize(window)
      @window = window
    end

    def get(name_or_options)
      name = name_or_options.is_a?(Hash) ? (name_or_options["name"] || name_or_options[:name]) : name_or_options
      raw = cookie_jar.cookies[name.to_s]
      raw ? PromiseValue.resolve(@window, build_record(name.to_s, raw)) : PromiseValue.resolve(@window, nil)
    end

    def get_all(name = nil)
      records = cookie_jar.cookies.map { |k, v| build_record(k, v) }
      records = records.select { |r| r["name"] == name.to_s } if name
      PromiseValue.resolve(@window, records)
    end

    alias getAll get_all

    def set(name_or_options, value = nil)
      if name_or_options.is_a?(Hash)
        opts = name_or_options.transform_keys(&:to_s)
        name = opts["name"]
        value = opts["value"]
      else
        name = name_or_options
      end

      cookie_jar.set_cookie("#{name}=#{value}")
      dispatch_event(
        CookieChangeEvent.new(
          "change",
          "changed" => [build_record(name.to_s, value.to_s)],
          "deleted" => []
        )
      )
      PromiseValue.resolve(@window, nil)
    end

    def delete(name_or_options)
      name = name_or_options.is_a?(Hash) ? (name_or_options["name"] || name_or_options[:name]) : name_or_options
      cookie_jar.cookies.delete(name.to_s)
      dispatch_event(
        CookieChangeEvent.new(
          "change",
          "changed" => [],
          "deleted" => [build_record(name.to_s, "")]
        )
      )
      PromiseValue.resolve(@window, nil)
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

    def cookie_jar
      # `document.cookie_jar` is private; we reach the same backing
      # store via the public `document.cookie` round-trip. Easier: use
      # instance_variable_get on the document.
      @window.document.instance_variable_get(:@cookie_jar)
    end

    def build_record(name, value)
      {
        "name" => name.to_s,
        "value" => value.to_s,
        "domain" => nil,
        "path" => "/",
        "expires" => nil,
        "secure" => false,
        "sameSite" => "strict"
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
