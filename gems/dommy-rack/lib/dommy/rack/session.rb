# frozen_string_literal: true

require "uri"
require "json"
require "tmpdir"

module Dommy
  module Rack
    # A single browser-like session over a Rack application. Owns the current
    # URL, document, cookie jar, persistent header store, and history; delegates
    # URL/redirect logic to Navigation and form data collection to FormSubmission.
    class Session
      # Element finding, scoping, field interaction, generic click, and query
      # matchers come from the shared interaction layer; the session adds
      # navigation (click_link / click_button / submit_form). `after_interaction`
      # stays the module's no-op (the no-JS session has nothing to settle).
      include Dommy::Interaction::Driver

      DEFAULT_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

      Config = Struct.new(
        :default_host, :follow_redirects, :max_redirects,
        :respect_method_override, :method_override_param,
        :user_agent, :accept, :enforce_same_origin, :follow_meta_refresh,
        :load_stylesheets,
        keyword_init: true
      )

      attr_reader :last_request, :last_response, :history

      # A factory `->(session) { js_runtime_host }` that binds a JS runtime to a
      # session for `javascript: true`. dommy-js-quickjs installs one when its
      # rack integration is required; nil means JS support is unavailable.
      class << self
        attr_accessor :javascript_runtime_factory

        # Fetching external <link rel=stylesheet> CSS (so class-based
        # visibility matches a browser) is browser-spec behavior, not plain
        # rack_test: an unset `load_stylesheets` follows `javascript` (a
        # browser spec runs page JS too). An explicit value always wins.
        def resolve_load_stylesheets(load_stylesheets, javascript)
          load_stylesheets.nil? ? javascript : load_stylesheets
        end
      end

      def initialize(app,
                     default_host: "http://example.org",
                     follow_redirects: true,
                     max_redirects: 5,
                     respect_method_override: true,
                     method_override_param: "_method",
                     user_agent: "DommyRack",
                     accept: DEFAULT_ACCEPT,
                     enforce_same_origin: true,
                     follow_meta_refresh: true,
                     load_stylesheets: nil,
                     javascript: false)
        @app = app
        @config = Config.new(
          default_host: default_host,
          follow_redirects: follow_redirects,
          max_redirects: max_redirects,
          respect_method_override: respect_method_override,
          method_override_param: method_override_param,
          user_agent: user_agent,
          accept: accept,
          enforce_same_origin: enforce_same_origin,
          follow_meta_refresh: follow_meta_refresh,
          load_stylesheets: self.class.resolve_load_stylesheets(load_stylesheets, javascript)
        ).freeze
        @cookie_jar = CookieJar.new
        @headers = HeaderStore.new
        @navigation = Navigation.new(self, @config)
        @history = History.new
        @current_url = nil
        @current_window = nil
        @last_request = nil
        @last_response = nil
        @scope_stack = []
        @request_listeners = []
        @response_listeners = []
        @document_loaded_listeners = []
        @js_runtime = build_js_runtime if javascript
      end

      # Whether this session runs page JavaScript (created with `javascript:
      # true`). When true, navigation boots `<script>` tags and the interaction
      # verbs drive JS handlers.
      def javascript? = !@js_runtime.nil?

      # Run JS for side effects against the current document's realm.
      def execute_script(script)
        require_js!.execute(script)
        nil
      end

      # Evaluate JS and return the value (DOM nodes decoded to Dommy objects).
      def evaluate_script(script) = require_js!.evaluate(script)

      # Settle work ready at the current virtual time (microtasks + due-now
      # timers + requestAnimationFrame). A future setTimeout(ms) needs
      # #advance_time.
      def settle
        require_js!.settle
        self
      end

      # Advance virtual time by `ms`, running timers that come due, then settle.
      def advance_time(ms)
        require_js!.advance_time(ms)
        self
      end

      # Uncaught JS errors / unhandled rejections and console output collected
      # by the JS runtime ([] when JS is disabled). A test integration fails on
      # non-empty js_errors.
      def js_errors = @js_runtime ? @js_runtime.js_errors : []
      def console = @js_runtime ? @js_runtime.console : []

      # Dispose the JS runtime(s). Safe to call when JS is disabled.
      def dispose_js
        @js_runtime&.dispose
        @js_runtime = nil
      end

      # --- Config readers used by collaborators ---

      def default_host = @config.default_host
      def follow_redirects? = @config.follow_redirects
      def max_redirects = @config.max_redirects
      def enforce_same_origin? = @config.enforce_same_origin
      def follow_meta_refresh? = @config.follow_meta_refresh
      def load_stylesheets? = @config.load_stylesheets
      def config = @config

      # --- Navigation API ---

      # Navigate to `path` (GET). For a `javascript: true` session, the loaded
      # page's scripts boot and then the page is settled (microtasks, due-now
      # timers, and requestAnimationFrame run) so it is ready to inspect /
      # interact without a manual #settle. Pass `settle: false` to observe the
      # page mid-flight (before on-load async work completes). No-op settle when
      # JS is disabled.
      def visit(path, settle: true)
        result = @navigation.navigate(method: "GET", url: path)
        self.settle if settle && @js_runtime
        result
      end

      def navigate(method: "GET", url:, params: nil, body: nil, headers: {})
        @navigation.navigate(method: method, url: url, params: params, body: body, headers: headers)
      end

      def reload
        raise Error, "no current page to reload" unless @last_request_args

        response, final_url = @navigation.run(**@last_request_args)
        apply_navigation_response(response, final_url)
        response
      end

      def back
        url = @history.back
        @navigation.revisit(url) if url
      end

      def forward
        url = @history.forward
        @navigation.revisit(url) if url
      end

      # --- Basic request API (navigates, updating page state) ---

      def get(path, headers: {})
        navigate(method: "GET", url: path, headers: headers)
      end

      def post(path, params: nil, body: nil, headers: {})
        navigate(method: "POST", url: path, params: params, body: body, headers: headers)
      end

      def put(path, params: nil, body: nil, headers: {})
        navigate(method: "PUT", url: path, params: params, body: body, headers: headers)
      end

      def patch(path, params: nil, body: nil, headers: {})
        navigate(method: "PATCH", url: path, params: params, body: body, headers: headers)
      end

      def delete(path, params: nil, body: nil, headers: {})
        navigate(method: "DELETE", url: path, params: params, body: body, headers: headers)
      end

      def request(method, path, params: nil, body: nil, headers: {})
        navigate(method: method, url: path, params: params, body: body, headers: headers)
      end

      # --- JSON request helpers (navigate with a JSON body) ---

      def post_json(path, data, headers: {})
        request_json("POST", path, data, headers: headers)
      end

      def put_json(path, data, headers: {})
        request_json("PUT", path, data, headers: headers)
      end

      def patch_json(path, data, headers: {})
        request_json("PATCH", path, data, headers: headers)
      end

      def delete_json(path, data, headers: {})
        request_json("DELETE", path, data, headers: headers)
      end

      # --- Persistent request headers (sent on every request) ---

      # A copy of the headers currently sent on every request. Mutate via
      # #set_header / #delete_header rather than this hash.
      def default_headers = @headers.to_h

      def set_header(name, value)
        @headers.set(name, value)
        self
      end

      def delete_header(name)
        @headers.delete(name)
        self
      end

      # HTTP Basic auth: sets a persistent Authorization header.
      def basic_auth(user, password)
        @headers.basic_auth(user, password)
        self
      end

      # Bearer-token auth: sets a persistent Authorization header.
      def authorization_bearer(token)
        @headers.bearer(token)
        self
      end

      # --- Fetch API (returns Response; does NOT change document or history) ---

      def fetch(url, method: "GET", headers: {}, body: nil, params: nil, redirect: :follow)
        @navigation.fetch(url, method: method, params: params, body: body, headers: headers, redirect: redirect)
      end

      # --- Current page state ---

      def current_url = @current_url

      def current_path
        @current_url && URI.parse(@current_url).path
      end

      def current_host
        @current_url && URI.parse(@current_url).host
      end

      def status = @last_response&.status
      def headers = @last_response&.headers
      def body = @last_response&.body
      def document = @current_window&.document

      # Parsed JSON of the most recent response, or nil if no request yet.
      def json(symbolize_names: false)
        @last_response&.json(symbolize_names: symbolize_names)
      end

      # --- Status predicates (delegate to the last response) ---

      def success? = @last_response&.success? || false
      def client_error? = @last_response&.client_error? || false
      def server_error? = @last_response&.server_error? || false
      def not_found? = @last_response&.not_found? || false

      # --- Redirect chain of the last navigation ---

      def redirects = @last_response&.redirects || []
      def redirected? = !redirects.empty?

      # --- Instrumentation hooks ---

      # Register a callback invoked with the Rack env just before each request.
      def on_request(&block)
        @request_listeners << block
        self
      end

      # Register a callback invoked with the Response after each request.
      def on_response(&block)
        @response_listeners << block
        self
      end

      # Register a callback invoked with the new Window each time a navigation
      # installs an HTML document (visit, redirects, link clicks, form submits,
      # back/forward, reload, meta refresh). This is the page-load lifecycle
      # seam a JavaScript runtime hooks to install window globals, execute
      # <script> tags, and fire DOMContentLoaded/load. Not invoked for #fetch
      # (which never changes the document) or for non-HTML responses.
      def on_document_loaded(&block)
        @document_loaded_listeners << block
        self
      end

      def html
        document&.to_html
      end

      def text
        document&.body&.text_content
      end

      # Write the current page HTML to `path` (default: a timestamped file in
      # the system temp dir) and return the path. For debugging.
      def save_page(path = nil)
        content = html
        raise Error, "no current page to save" if content.nil?

        path ||= ::File.join(Dir.tmpdir, "dommy-rack-#{Time.now.strftime("%Y%m%d%H%M%S")}.html")
        ::File.write(path, content)
        path
      end

      # --- DOM query helpers (delegate to the document) ---

      def at_css(selector)
        scope_root&.query_selector(selector)
      end

      def all_css(selector)
        scope_root&.query_selector_all(selector)
      end

      def at_xpath(xpath)
        document&.at_xpath(xpath)
      end

      def all_xpath(xpath)
        document ? document.xpath(xpath) : []
      end

      # --- Scoping ---
      # `within` / `with_scope` / `scope_root` / `scope_text` come from
      # Dommy::Interaction::Driver. `within_frame` is session-specific (it
      # fetches the frame document over the network).

      # Load the iframe matched by `locator` (id, name, or CSS; the sole frame
      # if omitted) and scope finds/matchers to its document for the block.
      def within_frame(locator = nil, &block)
        frame = find_frame(locator)
        raise ElementNotFoundError, "no iframe matching #{locator.inspect}" unless frame

        src = frame.get_attribute("src")
        raise Error, "iframe has no src" if src.nil? || src.empty?

        frame_doc = fetch(resolve_document_url(src), headers: referer_headers).document
        raise UnsupportedContentTypeError, "iframe did not return an HTML document" unless frame_doc

        with_scope(frame_doc, &block)
      end

      # --- Matchers ---
      # has_css? / has_no_css? / has_text? / has_no_text? / has_link? /
      # has_button? / has_field? come from Dommy::Interaction::Driver.

      # --- Link navigation ---

      def click_link(locator)
        click_link_element(finder.find_link(locator))
      end

      def click_link_element(element)
        href = element.get_attribute("href")
        raise ElementNotClickableError, "link has no href" if href.nil?

        scheme = href.split(":", 2).first.to_s.downcase
        raise UnsupportedURLError, "#{scheme}: URLs are not supported" if %w[javascript mailto].include?(scheme)
        return document if href.start_with?("#") # in-page fragment: no request

        target = resolve_document_url(href)
        return document if same_page_fragment?(target) # url + fragment to current page: no request

        navigate(method: "GET", url: target, headers: referer_headers)
      end

      # --- Form field setting ---
      # fill_in / choose / check / uncheck / attach_file / select / unselect
      # come from Dommy::Interaction::Driver (they now also fire input/change
      # events; a subsequent submit is what turns into a navigation).

      # --- Form submission ---

      def click_button(locator)
        button = finder.find_button(locator)
        # Only submit buttons submit a form. type=button / type=reset are
        # no-ops here since there is no JavaScript to handle their click.
        return button unless submit_button?(button)

        submit_form(finder.form_for(button), submitter: button)
      end

      def submit_form(form, submitter: nil)
        raise InvalidFormError, "element is not inside a form" if form.nil?

        result = FormSubmission.new(form, submitter, @config).submit!
        navigate(method: result[:method], url: resolve_document_url(result[:url]),
                 params: result[:params], headers: referer_headers)
      end

      alias submit submit_form

      # --- Cookie public API ---

      def cookies = @cookie_jar.all

      def set_cookie(name, value, path: "/", domain: nil, **opts)
        resolved_domain = domain || (@current_url && URI.parse(@current_url).host) || URI.parse(@config.default_host).host
        @cookie_jar.set!(name, value, domain: resolved_domain, path: path, **opts)
      end

      def get_cookie(name) = @cookie_jar.get(name)
      def clear_cookies = @cookie_jar.clear

      # --- Collaboration API used by Navigation ---
      # Public so Navigation can drive the session, but not part of the everyday
      # browsing API; prefer #visit / #get / #fetch etc.

      # Execute one request against the app. Stores response cookies but does
      # NOT update current_url / document / history.
      def raw_request(method, absolute_url, params: nil, body: nil, headers: {})
        # Remember the latest raw request so #reload can re-issue it. Note this
        # is the final request of any redirect chain: after a POST that
        # redirects (PRG), reload re-GETs the landing page rather than re-POSTing.
        @last_request_args = {method: method, url: absolute_url, params: params, body: body, headers: headers}
        env = RequestBuilder.new(@config).build(
          method: method,
          url: absolute_url,
          params: params,
          body: body,
          headers: @headers.merge(headers),
          cookie_string: @cookie_jar.cookies_for(absolute_url)
        )
        @last_request = env
        @request_listeners.each { |cb| cb.call(env) }
        status, response_headers, response_body = @app.call(env)
        response = Response.new(status, response_headers, response_body, url: absolute_url)
        response.set_cookie_strings.each do |sc|
          @cookie_jar.store_from_header(sc, absolute_url)
        end
        @response_listeners.each { |cb| cb.call(response) }
        response
      end

      # Apply a final navigation response: update last_response, current_url,
      # the document (HTML only), and the history stack.
      def apply_navigation_response(response, final_url, push_history: true)
        @last_response = response
        @current_url = final_url
        if response.html?
          @current_window = response.window
          # Fill external stylesheets before listeners (script boot /
          # DOMContentLoaded) run, so CSS-driven computed styles and :visible
          # are correct from the first observation.
          load_document_stylesheets(@current_window) if load_stylesheets?
          @document_loaded_listeners.each { |cb| cb.call(@current_window) }
        end
        @history.push(final_url) if push_history
      end

      # Resolve each same-origin `<link rel=stylesheet>` through the app and
      # fill its sheet (Dommy fetches nothing on its own). Best-effort: a
      # cross-origin href, a non-2xx response, or any fetch error just leaves
      # that link empty — its rules simply don't apply, never raising mid-load.
      def load_document_stylesheets(window)
        document = window&.document
        return unless document

        document.query_selector_all("link").each do |link|
          next unless link.respond_to?(:set_stylesheet_text)

          href = link.get_attribute("href").to_s
          next if href.empty? || link.get_attribute("rel").to_s !~ /\bstylesheet\b/i

          css = fetch_stylesheet_text(href)
          link.set_stylesheet_text(css) if css
        end
      end

      def fetch_stylesheet_text(href)
        response = fetch(href)
        return nil unless response&.status.to_i.between?(200, 299)

        response.body.to_s
      rescue StandardError
        nil
      end

      # After an interaction's events are dispatched (Ruby-side, synchronously
      # invoking JS handlers), drain the JS runtime so promise reactions settle
      # before the next line. A no-op when JS is disabled (the mixin default).
      def after_interaction
        @js_runtime&.drain
      end

      private

      def build_js_runtime
        factory = self.class.javascript_runtime_factory
        unless factory
          begin
            require "dommy/js/quickjs/rack"
          rescue LoadError
            # fall through to the helpful error below
          end
          factory = self.class.javascript_runtime_factory
        end
        unless factory
          raise Error, "javascript: true requires dommy-js-quickjs " \
                       "(add the gem and `require \"dommy/js/quickjs/rack\"`)"
        end
        factory.call(self)
      end

      def require_js!
        @js_runtime || raise(Error, "session was not created with javascript: true")
      end

      # Serialize data as a JSON body and navigate. A String is sent verbatim
      # (already-encoded JSON); anything else is run through JSON.generate.
      # Callers can override the default Content-Type/Accept via headers.
      def request_json(method, path, data, headers:)
        json_headers = {"Content-Type" => "application/json", "Accept" => "application/json"}.merge(headers)
        navigate(method: method, url: path,
                 body: data.is_a?(String) ? data : JSON.generate(data),
                 headers: json_headers)
      end

      # Link clicks and form submits send the current page as the Referer;
      # a bare visit does not.
      def referer_headers
        @current_url ? {"Referer" => @current_url} : {}
      end

      # A link to the current page that differs only by fragment does not
      # issue a request (browser behavior).
      def same_page_fragment?(target)
        return false unless @current_url

        t = URI.parse(target)
        c = URI.parse(@current_url)
        !t.fragment.nil? &&
          t.scheme == c.scheme && t.host == c.host && t.port == c.port &&
          t.path == c.path && t.query == c.query
      rescue URI::InvalidURIError
        false
      end

      # Resolve a document-relative href/action against <base href> (if any),
      # then the current URL, then the default host. Redirect Location
      # resolution is handled separately by Navigation against the request URL.
      def resolve_document_url(href)
        base = document&.base_uri
        base = current_url if base.nil? || base.empty?
        base ||= default_host
        URI.join(base, href.to_s).to_s
      rescue URI::InvalidURIError
        href.to_s
      end

      # finder / field_interactor / scope_root / with_scope / scope_text /
      # element_present? come from Dommy::Interaction::Driver.

      # Locate an iframe by id, name attribute, or CSS selector; the sole frame
      # in scope when no locator is given.
      def find_frame(locator)
        return scope_root&.query_selector("iframe, frame") if locator.nil?

        scope_root&.get_element_by_id(locator) ||
          scope_root&.query_selector("iframe[name='#{locator}'], frame[name='#{locator}']") ||
          scope_root&.query_selector(locator)
      end

      # A <button> defaults to type=submit; an <input> submits only for
      # type=submit or type=image.
      def submit_button?(button)
        if button.tag_name == "BUTTON"
          button.type == "submit"
        else
          %w[submit image].include?(button.type)
        end
      end

    end
  end
end
