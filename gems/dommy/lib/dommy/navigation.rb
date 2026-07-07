# frozen_string_literal: true

require "uri"

module Dommy
  # Navigation host seam. The core fires the *intent* to navigate (a link
  # activation, a `location.assign`, a reload, a cross-document history
  # traversal) at a single point — `Window#__internal_navigate__` — and the
  # attached delegate decides what actually happens. This keeps real page
  # replacement out of the DOM core (it has no network/session model) while
  # letting an embedder (dommy-rack, a core Browser, dommynx) wire it up.
  #
  # Same-document navigation (fragment changes / pushState) never reaches a
  # delegate — the core handles it directly via Location/History and fires
  # hashchange/popstate. Only cross-document navigation is delegated.
  #
  # A delegate is any object responding to:
  #
  #   navigate(url:, method: "GET", body: nil, params: nil, enctype: nil,
  #            headers: {}, replace: false, source:)
  #     url:     already-resolved absolute URL string
  #     method:  "GET" | "POST" | ...  (GET for links / location / reload)
  #     body:    a pre-serialized request body, or nil
  #     params:  a form submission's ordered [name, value] pair array (as
  #              produced by Dommy::Interaction::FormSubmission#submit!), left
  #              unserialized so the delegate can query-encode (GET) or build a
  #              urlencoded/multipart body (POST) itself; nil for non-form navs
  #     enctype: the form's enctype for `params` (urlencoded / multipart), or nil
  #     headers: extra request headers (Content-Type, ...)
  #     replace: true to replace the current history entry (location.replace,
  #              a reload, or a redirect)
  #     source:  :link | :form | :location | :reload | :traverse — advisory,
  #              for diagnostics / policy
  #
  #   traverse(delta)
  #     A cross-document history traversal by `delta` entries. With no bfcache
  #     (a Dommy design decision) this re-fetches the target entry's URL, so an
  #     implementation may reduce it to a `navigate`.
  module Navigation
    # The default delegate: it performs no navigation, only *records* each
    # attempt so tests can assert "a navigation to X was triggered" and the
    # observable behaviour is unchanged from before the seam existed.
    class NullDelegate
      attr_reader :attempts

      def initialize
        @attempts = []
      end

      def navigate(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, headers: {}, replace: false)
        @attempts << {
          url: url, method: method, body: body, params: params, enctype: enctype,
          headers: headers, replace: replace, source: source
        }
        nil
      end

      def traverse(delta)
        @attempts << {traverse: delta, source: :traverse}
        nil
      end
    end

    # Raised when a navigation follows more redirects than allowed.
    class TooManyRedirectsError < StandardError; end

    # URL resolution + redirect following over a `Resources` adapter. This is the
    # engine-agnostic core of "fetch the document at this navigation target": it
    # folds GET params into the query, serializes a POST body, follows 3xx
    # redirects (303→GET, 301/302 POST→GET, 307/308 keep method+body), and
    # returns `[Resources::Response | nil, final_url]`. The Rack session's own
    # redirect loop is the reference; this is its Resources-based generalization
    # so the core `Browser` can navigate without Rack.
    class Fetcher
      REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
      KEEP_METHOD_STATUSES = [307, 308].freeze
      QUERY_METHODS = %w[GET HEAD].freeze

      def initialize(resources, max_redirects: 20)
        @resources = resources
        @max_redirects = max_redirects
      end

      # Resolve + issue the request, following redirects. `params` is an ordered
      # [name, value] array (form data set); it folds into the query for GET/HEAD
      # and becomes the request body otherwise. Returns [response|nil, final_url];
      # a nil response means "nothing served this URL" (stay on the current page).
      def request(method:, url:, params: nil, body: nil, enctype: nil, headers: {})
        return [nil, url.to_s] unless @resources

        verb = method.to_s.upcase
        target = url.to_s
        hdrs = headers.dup
        if params && QUERY_METHODS.include?(verb)
          target = append_query(target, params)
          params = nil
        elsif params
          body, content_type = encode_body(params, enctype)
          hdrs["Content-Type"] ||= content_type if content_type
        end
        run(verb, target, body, hdrs, 0)
      end

      # Merge ordered [name, value] params into `url`'s query, keeping any
      # existing query and a trailing fragment (browser address-bar form).
      def append_query(url, params)
        encoded = URI.encode_www_form(params)
        return url if encoded.empty?

        base, hash, fragment = url.to_s.partition("#")
        sep = base.include?("?") ? "&" : "?"
        "#{base}#{sep}#{encoded}#{hash}#{fragment}"
      end

      private

      def run(verb, target, body, headers, count)
        response = @resources.request(method: verb, url: target, headers: headers, body: body)
        return [nil, target] unless response

        status = response.status.to_i
        location = header(response, "location")
        if REDIRECT_STATUSES.include?(status) && location && !location.empty?
          raise TooManyRedirectsError, "exceeded #{@max_redirects} redirects" if count >= @max_redirects

          nxt = resolve(location, target)
          nverb = redirect_method(status, verb)
          nbody = KEEP_METHOD_STATUSES.include?(status) ? body : nil
          return run(nverb, nxt, nbody, headers, count + 1)
        end

        [response, response.url || target]
      end

      # Serialize a form data set to a request body. multipart is approximated as
      # urlencoded (the core test browser has no file uploads); text/plain uses
      # the WHATWG plain-text form; everything else is urlencoded.
      def encode_body(params, enctype)
        case enctype.to_s
        when "text/plain"
          [params.map { |n, v| "#{n}=#{v}" }.join("\r\n") + "\r\n", "text/plain;charset=UTF-8"]
        else
          [URI.encode_www_form(params), "application/x-www-form-urlencoded"]
        end
      end

      def redirect_method(status, original)
        case status
        when 303 then "GET"
        when 301, 302 then original == "POST" ? "GET" : original
        else original # 307, 308 keep the method
        end
      end

      def resolve(location, base)
        URI.join(base, location).to_s
      rescue URI::InvalidURIError
        location.to_s
      end

      # Case-insensitive header lookup over the plain Hash a Resources::Response
      # carries.
      def header(response, name)
        headers = response.headers || {}
        key = headers.keys.find { |k| k.to_s.casecmp?(name) }
        key && headers[key]
      end
    end

    # Browser-tab-style joint history: ONE ordered stack over both full-document
    # navigations and same-document (pushState) entries. Each entry remembers its
    # window and that window's own history index, so back/forward can choose
    # between a same-document popstate traversal (the entry's window is still
    # live) and a full re-fetch (document boundary). Mirrors dommy-rack's
    # `Rack::History`; kept in core so the embeddable `Browser` has a tab history
    # without depending on Rack.
    class JointHistory
      Entry = Struct.new(:url, :window, :windex)

      def initialize
        @stack = []
        @index = -1
      end

      def push(url, window: nil, windex: nil)
        kept = @index >= 0 ? @stack[0..@index] : []
        @stack = kept + [Entry.new(url, window, windex)]
        @index = @stack.size - 1
        url
      end

      def back
        return nil if @index <= 0

        @index -= 1
        current_entry
      end

      def forward
        return nil if @index >= @stack.size - 1

        @index += 1
        current_entry
      end

      # Re-bind the current entry to a fresh window + url (a reload / revisit
      # re-loaded into a new document), so later same-document sync matches it.
      def rebind_current(url: nil, window:, windex:)
        entry = current_entry
        return unless entry

        entry.url = url if url
        entry.window = window
        entry.windex = windex
      end

      # Mirror a same-document traversal the page performed itself (JS
      # history.back()): move the cursor to the entry recorded for (window,
      # windex). No-op when unknown.
      def sync_to(window, windex)
        i = @stack.index { |e| e.window.equal?(window) && e.windex == windex }
        @index = i if i
        current_entry
      end

      def current_entry = (@stack[@index] if @index >= 0)
      def current = current_entry&.url
      def length = @stack.size
      def entries = @stack.map(&:url)
    end
  end
end
