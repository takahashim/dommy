# frozen_string_literal: true

require_relative "internal/url_parser"

module Dommy
  # `window.location` polyfill. The Window owns one Location and one
  # History instance, and they share the same underlying state. Hash
  # / pushState / replaceState all flow through `__internal_set_url__`.
  #
  # Backed by an `Internal::UrlParser::Record` (the same WHATWG basic URL
  # parser `Dommy::URL` uses), never stdlib `URI` — so every getter/setter
  # matches the URL Standard's parsing and serialization rules exactly.
  class Location
    def initialize(window, origin: "http://localhost", pathname: "/", search: "", hash: "")
      @window = window
      @record = Internal::UrlParser.parse("#{origin}#{pathname}#{search}#{hash}")
    end

    def __js_get__(key)
      case key
      when "origin"
        origin
      when "pathname"
        Internal::UrlParser.serialize_path(@record)
      when "search"
        current_search
      when "hash"
        current_hash
      when "href"
        href
      when "host"
        host
      when "hostname"
        @record.host.to_s
      when "protocol"
        "#{@record.scheme}:"
      when "port"
        @record.port.nil? ? "" : @record.port.to_s
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        __internal_navigate_to__(value.to_s, replace: false, source: :location)
      when "hash"
        set_hash(value.to_s)
      when "pathname"
        set_pathname(value.to_s)
      when "search"
        set_search(value.to_s)
      when "host"
        set_host(value.to_s)
      when "hostname"
        set_hostname(value.to_s)
      when "port"
        set_port(value.to_s)
      when "protocol"
        parse_into("#{value}:", :scheme_start)
      end
    end

    include Bridge::Methods
    js_methods %w[assign replace reload toString]
    def __js_call__(method, args)
      case method
      when "assign"
        __internal_navigate_to__(args[0].to_s, replace: false, source: :location)
      when "replace"
        __internal_navigate_to__(args[0].to_s, replace: true, source: :location)
      when "reload"
        # A reload re-requests the current URL (never same-document).
        @window.__internal_navigate__(url: href, method: "GET", replace: true, source: :reload)
      when "toString"
        href
      end
    end

    def href
      Internal::UrlParser.serialize(@record)
    end

    # Internal — accepts an absolute or relative URL string and updates the
    # record. Called by History pushState / replaceState (with `fire_hash:
    # false`, since a pushState never fires hashchange) and by the
    # same-document navigation path. `fire_hash` gates the hashchange event
    # so callers that handle the fragment-change signal themselves can
    # suppress it. A parse failure leaves the record unchanged — every real
    # caller has already had `raw` validated by `resolve`.
    def __internal_set_url__(raw, fire_hash: true)
      previous_hash = current_hash
      previous_href = href
      @record = Internal::UrlParser.parse(raw, @record)
      @window.fire_hashchange(previous_href, href) if fire_hash && previous_hash != current_hash
    rescue Internal::UrlParser::Failure
      nil
    end

    # `location.href = X` / `assign` / `replace`, and the shared entry point for
    # a hyperlink's follow-the-hyperlink. A navigation that changes only the
    # fragment is same-document (always updates the hash + fires hashchange); any
    # other change is cross-document — the intent is handed to the delegate.
    #
    # `sync_cross_doc` controls whether a cross-document target also mutates the
    # URL parts synchronously: true for `location.href=`/assign/replace (a
    # backward-compatible behavior existing code relies on), false for a link
    # click (which leaves the location untouched until the delegate actually
    # navigates — so "nothing happened" is observable with the default
    # NullDelegate). A real delegate rebinds Location on document replacement
    # regardless, so this only affects the no-op default.
    def __internal_navigate_to__(raw, source:, replace: false, sync_cross_doc: true)
      target = resolve(raw)
      if target.nil?
        # A URL the parser rejects: the Location API throws, following a
        # hyperlink to one does nothing.
        raise DOMException::SyntaxError, "#{raw.inspect} is not a valid URL" if source == :location

        return
      end
      if same_document?(@record, target)
        __internal_set_url__(raw)
      else
        __internal_set_url__(raw, fire_hash: false) if sync_cross_doc
        @window.__internal_navigate__(url: Internal::UrlParser.serialize(target), method: "GET", replace: replace, source: source)
      end
    end

    private

    # Resolve a possibly-relative URL against the current record with the
    # URL parser; nil when it fails. Returns a Record, not a string, so the
    # caller can compare fields without a round trip through serialize+parse.
    def resolve(raw)
      Internal::UrlParser.parse(raw, @record)
    rescue Internal::UrlParser::Failure
      nil
    end

    # Two URLs address the same document when everything but the fragment matches.
    def same_document?(a, b)
      a.scheme == b.scheme && a.host == b.host && a.port == b.port &&
        a.path == b.path && a.query == b.query
    end

    def origin
      return "" if @record.host.nil?

      port_part = @record.port ? ":#{@record.port}" : ""
      "#{@record.scheme}://#{@record.host}#{port_part}"
    end

    def host
      return "" if @record.host.nil?

      @record.port ? "#{@record.host}:#{@record.port}" : @record.host
    end

    def current_search
      q = @record.query
      q.nil? || q.empty? ? "" : "?#{q}"
    end

    def current_hash
      f = @record.fragment
      f.nil? || f.empty? ? "" : "##{f}"
    end

    def set_hash(value)
      previous_hash = current_hash
      previous_href = href
      v = value.delete_prefix("#")
      if v.empty?
        @record.fragment = nil
      else
        @record.fragment = +""
        parse_into(v, :fragment)
      end
      # Setting the fragment is always same-document — fire hashchange with the
      # full URLs before/after (no delegate navigation).
      @window.fire_hashchange(previous_href, href) if current_hash != previous_hash
    end

    def set_pathname(value)
      return if @record.opaque_path?

      @record.path = []
      parse_into(value, :path_start)
    end

    def set_host(value)
      return if @record.opaque_path?

      parse_into(value, :host)
    end

    def set_hostname(value)
      return if @record.opaque_path?

      parse_into(value, :hostname)
    end

    def set_search(value)
      if value.empty?
        @record.query = nil
      else
        @record.query = +""
        parse_into(value.delete_prefix("?"), :query)
      end
    end

    def set_port(value)
      return if cannot_have_credentials?

      if value.empty?
        @record.port = nil
      else
        parse_into(value, :port)
      end
    end

    def cannot_have_credentials?
      @record.host.nil? || @record.host == "" || @record.scheme == "file"
    end

    # Run the parser from `state` into the current record; a rejected value
    # changes nothing (WHATWG URLUtils setters).
    def parse_into(value, state)
      Internal::UrlParser.parse_with_override(value.to_s, @record, state)
    rescue Internal::UrlParser::Failure
      nil
    end
  end
end
