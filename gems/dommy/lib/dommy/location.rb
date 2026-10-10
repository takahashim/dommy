# frozen_string_literal: true

require_relative "internal/url_parser"
require_relative "internal/url_record_accessors"

module Dommy
  # `window.location` polyfill. The Window owns one Location and one
  # History instance, and they share the same underlying state. Hash
  # / pushState / replaceState all flow through `__internal_set_url__`.
  #
  # Backed by an `Internal::UrlParser::Record` (the same WHATWG basic URL
  # parser `Dommy::URL` uses), never stdlib `URI` — so every getter/setter
  # matches the URL Standard's parsing and serialization rules exactly.
  class Location
    # host/hostname/port/protocol/pathname (+ the private
    # cannot_have_credentials?/parse_into they share) come from the mixin —
    # identical to URL's, which holds the same kind of record. Re-privatized
    # below: Location, unlike URL, exposes these only through
    # __js_get__/__js_set__, not as public Ruby methods.
    include Internal::UrlRecordAccessors
    private :host, :host=, :hostname, :hostname=, :port, :port=, :protocol, :protocol=, :pathname, :pathname=

    def initialize(window, origin: "http://localhost", pathname: "/", search: "", hash: "")
      @window = window
      @record = Internal::UrlParser.parse("#{origin}#{pathname}#{search}#{hash}")
    end

    def __js_get__(key)
      case key
      when "origin"
        origin
      when "pathname"
        pathname
      when "search"
        current_search
      when "hash"
        current_hash
      when "href"
        href
      when "host"
        host
      when "hostname"
        hostname
      when "protocol"
        protocol
      when "port"
        port
      when "ancestorOrigins"
        ancestor_origins
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      # Every setter in HTML's Location begins "if this's relevant Document is
      # null, then return". A page can hold on to a removed frame's location,
      # and what it holds is inert: readable, and deaf to every write.
      return unless browsing_context?

      case key
      when "href"
        __internal_navigate_to__(value.to_s, replace: false, source: :location)
      when "hash"
        set_hash(value.to_s)
      when "search"
        set_search(value.to_s)
      when "pathname"
        navigate_copy { |copy| copy.pathname = value.to_s }
      when "host"
        navigate_copy { |copy| copy.host = value.to_s }
      when "hostname"
        navigate_copy { |copy| copy.hostname = value.to_s }
      when "port"
        navigate_copy { |copy| copy.port = value.to_s }
      when "protocol"
        set_protocol(value.to_s)
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
        # A reload re-requests the current URL (never same-document), and does
        # nothing at all without a browsing context to reload.
        @window.__internal_navigate__(url: href, method: "GET", replace: true, source: :reload) if browsing_context?
      when "toString"
        href
      end
    end

    def href
      Internal::UrlParser.serialize(@record)
    end

    # Internal — establish the document's URL: accepts an absolute or relative
    # URL string and updates the record, without navigating and without firing
    # any event. Called by embedders when they know where the document lives,
    # and by History for its own URL updates. A parse failure leaves the record
    # unchanged. (`fire_hash` is accepted for compatibility and ignored: every
    # hashchange now comes from a fragment navigation or a traversal.)
    def __internal_set_url__(raw, fire_hash: false) # rubocop:disable Lint/UnusedMethodArgument
      @record = Internal::UrlParser.parse(raw, @record)
      nil
    rescue Internal::UrlParser::Failure
      nil
    end

    # `location.href = X` / `assign` / `replace`, and the shared entry point for
    # a hyperlink's follow-the-hyperlink. `raw` is parsed against the document
    # base URL; then it is navigated to (see #navigate_record).
    #
    # `sync_cross_doc` controls whether a cross-document target also mutates the
    # URL parts synchronously: true for `location.href=`/assign/replace (a
    # backward-compatible behavior existing code relies on), false for a link
    # click (which leaves the location untouched until the delegate actually
    # navigates — so "nothing happened" is observable with the default
    # NullDelegate). A real delegate rebinds Location on document replacement
    # regardless, so this only affects the no-op default.
    def __internal_navigate_to__(raw, source:, replace: false, sync_cross_doc: true)
      return unless browsing_context?

      target = resolve(raw)
      if target.nil?
        # A URL the parser rejects: the Location API throws, following a
        # hyperlink to one does nothing.
        raise DOMException::SyntaxError, "#{raw.inspect} is not a valid URL" if source == :location

        return
      end
      replace ||= source == :location && loading_without_activation?
      navigate_record(target, source: source, replace: replace, sync_cross_doc: sync_cross_doc)
    end

    private

    # HTML "Location-object navigate" step 2: while the document is still
    # loading, a navigation made by script without transient user activation
    # replaces the current entry instead of adding one. One a click handler
    # makes during the load is the user's, and adds an entry.
    def loading_without_activation?
      !@window.__internal_completely_loaded__? && !@window.__internal_transient_activation__?
    end

    # The navigate algorithm's history handling and its same-document branch.
    # A URL equal to the document's own is a "replace"; so is any navigation
    # away from an initial about:blank document. A URL that differs from the
    # active entry's only in its fragment — and HAS a fragment — is a fragment
    # navigation, which stays in this document; anything else is
    # cross-document and handed to the navigation delegate.
    def navigate_record(target, source:, replace:, sync_cross_doc:)
      url = Internal::UrlParser.serialize(target)
      replace = true if url == href || @window.__internal_initial_about_blank__?
      if !target.fragment.nil? && same_document?(@record, target)
        @window.history.__internal_navigate_to_fragment__(url, replace: replace)
      else
        @record = target if sync_cross_doc
        @window.__internal_navigate__(url: url, method: "GET", replace: replace, source: source)
      end
      nil
    end

    # Location-object navigate to an edited copy of this Location's URL — the
    # shared tail of the host / hostname / port / pathname setters. The block
    # edits the copy through the URL-component setters.
    def navigate_copy
      copy = RecordEditor.new(copy_record)
      yield copy
      location_object_navigate(copy.record)
    end

    def location_object_navigate(target)
      replace = loading_without_activation?
      navigate_record(target, source: :location, replace: replace, sync_cross_doc: true)
    end

    def copy_record = @record.dup

    # Resolve a possibly-relative URL against the document base URL with the
    # URL parser; nil when it fails. Returns a Record, not a string, so
    # `__internal_navigate_to__` can both compare fields and adopt it directly.
    def resolve(raw)
      base = @window.document&.base_uri.to_s
      Internal::UrlParser.parse(raw, base.empty? ? @record : Internal::UrlParser.parse(base))
    rescue Internal::UrlParser::Failure
      nil
    end

    # Two URLs address the same document when everything but the fragment matches.
    def same_document?(a, b)
      a.scheme == b.scheme && a.username == b.username && a.password == b.password &&
        a.host == b.host && a.port == b.port && a.path == b.path && a.query == b.query
    end

    # Whether this Location still has a browsing context to navigate. A nested
    # one loses it when the frame that held its document leaves the tree — the
    # Window survives (a script may still hold it), the navigable does not. A
    # top-level Window has no frame element and always has one.
    def browsing_context?
      @window.navigable?
    end

    # `location.ancestorOrigins` — the origins of this browsing context's
    # ancestors, innermost first. Empty for a top-level context, and for one
    # that no longer has a context at all.
    #
    # [SameObject], so the list is built once and answers live: a page that
    # holds `location.ancestorOrigins` holds the same object the next read would
    # give it, which is what the IDL promises: a live DOMStringList.
    def ancestor_origins
      @ancestor_origins ||= DOMStringList.new { current_ancestor_origins }
    end

    def current_ancestor_origins
      origins = []
      frame = @window.frame_element if browsing_context?
      while frame
        window = frame.owner_document&.default_view
        break unless window

        origins << window.origin
        frame = window.frame_element
      end
      origins
    end

    def origin
      # A Location with no browsing context has an opaque origin, which
      # serializes as "null".
      return "null" unless browsing_context?

      # The URL's origin: a tuple for http(s) and the other special schemes,
      # opaque ("null") for about:blank, data:, file: and the like.
      Internal::Origin.of_url(href)
    end

    def current_search
      q = @record.query
      q.nil? || q.empty? ? "" : "?#{q}"
    end

    def current_hash
      f = @record.fragment
      f.nil? || f.empty? ? "" : "##{f}"
    end

    # The hash setter: parse the value into a copy's (emptied) fragment; leave
    # the URL alone when the fragment would not change (deployed content sets
    # `location.hash` redundantly on scroll), otherwise navigate — which, the
    # rest of the URL being equal, is a fragment navigation.
    #
    # This is where Location parts company with the URL API, deliberately:
    # `url.hash = ""` sets the fragment to NULL and the "#" goes away, whereas
    # here the copy's fragment is first set to the EMPTY STRING, so clearing a
    # fragment that is there leaves the "#" behind ("?q=1#x" -> "?q=1#"). Both
    # are pinned by WPT (location-hash-setter-empty-string.html and
    # url/url-setters).
    # https://html.spec.whatwg.org/multipage/nav-history-apis.html#dom-location-hash
    def set_hash(value)
      this_fragment = @record.fragment || ""
      copy = copy_record
      copy.fragment = +""
      begin
        Internal::UrlParser.parse_with_override(value.delete_prefix("#"), copy, :fragment)
      rescue Internal::UrlParser::Failure
        nil
      end
      return if copy.fragment == this_fragment

      location_object_navigate(copy)
    end

    def set_search(value)
      copy = copy_record
      if value.empty?
        copy.query = nil
      else
        copy.query = +""
        begin
          Internal::UrlParser.parse_with_override(value.delete_prefix("?"), copy, :query)
        rescue Internal::UrlParser::Failure
          nil
        end
      end
      location_object_navigate(copy)
    end

    # The protocol setter: a value the URL parser rejects is a SyntaxError, and
    # a resulting scheme other than http(s) navigates nowhere.
    def set_protocol(value)
      copy = copy_record
      begin
        Internal::UrlParser.parse_with_override("#{value}:", copy, :scheme_start)
      rescue Internal::UrlParser::Failure
        raise DOMException::SyntaxError, "'#{value}' is an invalid protocol"
      end
      return unless %w[http https].include?(copy.scheme)

      location_object_navigate(copy)
    end

    # A URL record edited through the URLUtils component setters, for the
    # Location setters that navigate to a modified copy of the current URL.
    class RecordEditor
      include Internal::UrlRecordAccessors

      attr_reader :record

      def initialize(record)
        @record = record
      end
    end
  end
end
