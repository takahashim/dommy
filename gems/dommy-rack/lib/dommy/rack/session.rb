# frozen_string_literal: true

require "uri"
require "json"
require "tmpdir"

module Dommy
  module Rack
    # The NavigationDelegate (Dommy::Navigation port) attached to each page's
    # window: it forwards a page-initiated navigation/traversal intent to the
    # owning Session (which defers and performs it at the next drain). Bound to
    # the specific window so a stale, navigated-away page cannot steer the
    # session — the Session checks window identity before recording.
    class PageNavigationDelegate
      def initialize(session, window)
        @session = session
        @window = window
      end

      def navigate(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, headers: {}, replace: false)
        @session.__enqueue_page_navigation__(@window, {
          url: url, method: method, body: body, params: params, enctype: enctype,
          headers: headers, replace: replace, source: source
        })
      end

      def traverse(delta)
        @session.__enqueue_page_traverse__(@window, delta)
      end
    end

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

      attr_reader :last_request, :last_response, :history, :trace

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
                     javascript: false,
                     network_executor: nil,
                     cross_origin_subresources: :same_origin,
                     approximate_layout: false,
                     trace: false,
                     trace_level: :verbose,
                     trace_dom: false,
                     trace_snapshots: false)
        @app = app
        # An optional off-thread network executor (responds to
        # `submit(job) { |result| }`, e.g. dommynx's NetworkPool). When present,
        # subresource fetch / XHR run on a worker and resolve via a
        # DeferredResponse; when nil (the default), everything stays synchronous
        # and deterministic. See #build_subresource_fetch_job.
        @network_executor = network_executor
        # Cross-origin subresource policy. `:same_origin` (default) loads only
        # same-origin `<script src>` / fetch / XHR unless a host is allowlisted
        # (an embedding browser prompts and opts hosts in). `:open` loads any
        # cross-origin subresource like a real browser — the network backend's
        # SSRF guard is then the security boundary (it still cannot reach private
        # hosts). dommynx defaults to `:open` so modern third-party-bundled sites
        # are readable; the test/Rails front end keeps the conservative default.
        @cross_origin_subresources = cross_origin_subresources
        # Opt the page's windows into best-effort geometry (non-zero
        # getBoundingClientRect / client* / offset*) — a browser front end turns
        # this on so sites that bail on all-zero rects render; off by default
        # keeps the deterministic no-layout contract. Applied per window in
        # #apply_navigation_response before its scripts boot.
        @approximate_layout = approximate_layout
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
        @subresource_allowlist = []        # hosts allowed for cross-origin <script>/fetch/XHR
        @blocked_subresource_hosts = []    # cross-origin hosts declined since the last reset (awaiting a decision)
        @dropped_subresource_hosts = []    # hosts dropped by the denylist (deliberate; never prompted)
        @subresource_host_blocker = nil    # embedder-supplied ->(host){bool} denylist (e.g. trackers)
        @js_runtime = build_js_runtime if javascript
        # Built last so it can subscribe to the (already-created) JS runtime's
        # console / js_error / script seams as well as the request/document seams.
        @trace = Trace.attach(self, level: trace_level, dom: trace_dom, snapshots: trace_snapshots) if trace
      end

      # Whether this session runs page JavaScript (created with `javascript:
      # true`). When true, navigation boots `<script>` tags and the interaction
      # verbs drive JS handlers.
      def javascript? = !@js_runtime.nil?

      # The bound JS runtime (a SessionRuntime), or nil when JS is disabled.
      # Exposed for the Trace to subscribe to the runtime's console / js_error /
      # script seams; not part of the everyday browsing API.
      def __internal_js_runtime = @js_runtime

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
        __flush_page_navigation__
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

      # Full session teardown: the JS runtime(s) plus any live WebSocket
      # transports. Safe to call when JS is disabled, and repeatedly.
      def dispose
        Array(@live_websocket_transports).each(&:dispose)
        @live_websocket_transports = nil
        dispose_js
      end

      # Dispose the JS runtime(s) only. Safe to call when JS is disabled.
      def dispose_js
        @js_runtime&.dispose
        @js_runtime = nil
      end

      # Factory for the window's websocket_connector seam (installed per
      # realm by SessionRuntime): a same-origin `new WebSocket(url)` connects
      # to the Rack app itself over rack.hijack (see WebSocketTransport), so
      # ActionCable-backed features (Turbo Streams broadcasts, …) work
      # in-process. A cross-origin URL returns nil, leaving the WebSocket on
      # its in-memory stub.
      def __internal_websocket_connector(window)
        lambda do |ws, url, _protocols|
          base = @current_url || default_host
          target = WebSocketTransport.rack_target(url, base: base)
          next nil unless target

          transport = WebSocketTransport.new(
            app: @app, ws: ws, scheduler: window.scheduler, url: target,
            origin: Url.origin(target), cookie_string: @cookie_jar.cookies_for(target.to_s)
          )
          (@live_websocket_transports ||= []) << transport
          transport
        end
      end

      # --- Config readers used by collaborators ---

      def default_host = @config.default_host
      def follow_redirects? = @config.follow_redirects
      def max_redirects = @config.max_redirects
      def enforce_same_origin? = @config.enforce_same_origin
      def follow_meta_refresh? = @config.follow_meta_refresh
      def load_stylesheets? = @config.load_stylesheets
      def config = @config
      def network_executor = @network_executor

      # Whether cross-origin subresources load freely (browser-like), with the
      # backend SSRF guard as the only boundary. See cross_origin_subresources.
      def open_subresources? = @cross_origin_subresources == :open

      # Whether an off-thread network completion is waiting to be applied on the
      # page thread (a worker finished and posted its response to the scheduler
      # inbox, not yet drained). A run loop ORs this with its executor's in-flight
      # count to decide whether to keep ticking while async subresources load.
      def external_network_pending?
        !!@current_window&.scheduler&.external_pending?
      end

      # --- Cross-origin subresource policy ---
      #
      # By default only same-origin `<script src>` / `fetch` / XHR load (see
      # Dommy::Rack::Resources). Hosts allowed here also load — an embedding
      # browser prompts the user for a blocked host and reloads. The network
      # backend's SSRF guard still applies, so this never reaches private hosts.

      def allow_subresource_host(host)
        host = host.to_s
        @subresource_allowlist << host unless host.empty? || @subresource_allowlist.include?(host)
        self
      end

      def subresource_host_allowed?(host) = @subresource_allowlist.include?(host.to_s)

      # An embedder-owned denylist predicate consulted before any subresource is
      # fetched (even in `:open` mode). A text/headless client uses it to drop
      # tracker/ad hosts it never renders — the host is recorded as blocked so a
      # UI can still surface it. Generic mechanism only: the host set and the
      # matching rule (exact / domain-suffix) live in the embedder.
      attr_accessor :subresource_host_blocker

      def subresource_host_blocked?(host)
        blocker = @subresource_host_blocker
        return false unless blocker

        !!blocker.call(host.to_s)
      end

      # Hosts the denylist dropped this page. Distinct from
      # blocked_subresource_hosts: a dropped host was refused on purpose (a
      # tracker the embedder never wants), so the UI surfaces it but never offers
      # to load it, whereas a blocked host is a cross-origin candidate awaiting a choice.
      def dropped_subresource_hosts = @dropped_subresource_hosts.dup

      def reset_dropped_subresource_hosts
        @dropped_subresource_hosts.clear
        self
      end

      # Internal: Resources records a denylist-dropped host here.
      def __internal_record_dropped_subresource(host)
        host = host.to_s
        @dropped_subresource_hosts << host unless host.empty? || @dropped_subresource_hosts.include?(host)
      end

      # Cross-origin hosts whose subresources were declined since the last reset,
      # so a UI can offer to allow them.
      def blocked_subresource_hosts = @blocked_subresource_hosts.dup

      def reset_blocked_subresource_hosts
        @blocked_subresource_hosts.clear
        self
      end

      # Internal: Resources records a declined cross-origin host here.
      def __internal_record_blocked_subresource(host)
        host = host.to_s
        @blocked_subresource_hosts << host unless host.empty? || @blocked_subresource_hosts.include?(host)
      end

      # --- Navigation API ---

      # Navigate to `path` (GET). For a `javascript: true` session, the loaded
      # page's scripts boot and then the page is settled (microtasks, due-now
      # timers, and requestAnimationFrame run) so it is ready to inspect /
      # interact without a manual #settle. Pass `settle: false` to observe the
      # page mid-flight (before on-load async work completes). No-op settle when
      # JS is disabled.
      def visit(path, settle: true)
        @trace&.__internal_open_action(:visit, path)
        result = @navigation.navigate(method: "GET", url: path)
        self.settle if settle && @js_runtime
        result
      end

      def navigate(method: "GET", url:, params: nil, body: nil, headers: {}, replace: false)
        @navigation.navigate(method: method, url: url, params: params, body: body, headers: headers, replace: replace)
      end

      def reload
        raise Error, "no current page to reload" unless @last_request_args

        response, final_url = @navigation.run(**@last_request_args)
        apply_navigation_response(response, final_url)
        response
      end

      # Traverse the joint history like a browser's back button: a
      # same-document target within the LIVE page (a Turbo Drive pushState
      # entry) moves window.history and fires popstate — Turbo's restoration
      # visit runs, no full request; a target across a document boundary
      # re-requests the URL. Returns the destination URL, or nil at the edge.
      # A JS session may need `settle` afterwards for the restoration fetch.
      def back
        traverse_history(:back)
      end

      def forward
        traverse_history(:forward)
      end

      # --- NavigationDelegate port (see Dommy::Navigation) ---

      # The delegate attached to each page's window (in SessionRuntime). A
      # page-initiated navigation — a JS `location.href=` / `form.submit()`, a
      # submitted form, an activated `<a>` — routes here. Navigation is a task:
      # performing it synchronously could dispose the JS realm still on the
      # stack, so it is recorded and performed at the next drain (#after_interaction
      # / #settle), exactly like the standalone Browser.
      def __navigation_delegate_for__(window)
        PageNavigationDelegate.new(self, window)
      end

      def __enqueue_page_navigation__(window, nav)
        # A retained handle to a navigated-away page must not steer the session.
        return unless window.equal?(@current_window)

        @pending_navigation = nav
      end

      def __enqueue_page_traverse__(window, delta)
        return unless window.equal?(@current_window)

        @pending_navigation = {traverse: delta}
      end

      # Perform a recorded page navigation, if any. Called after the JS runtime
      # drains so the document/realm swap never runs with the outgoing realm's
      # JS on the stack.
      def __flush_page_navigation__
        nav = @pending_navigation
        return unless nav

        @pending_navigation = nil
        if nav.key?(:traverse)
          traverse_history(nav[:traverse].negative? ? :back : :forward)
        else
          perform_page_navigation(nav)
        end
      rescue CrossOriginError, UnsupportedURLError, InvalidFormError, TooManyRedirectsError
        # A page-initiated navigation that is blocked, unsupported, or loops on
        # redirects is dropped (a browser blocks/abandons it); it must not crash
        # the drain the way a Ruby-driven `visit` (which re-raises) does.
        nil
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
        @trace&.__internal_open_action(:click_link, locator)
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
        @trace&.__internal_open_action(:click_button, locator)
        button = finder.find_button(locator)
        # Only submit buttons submit a form. type=button / type=reset are
        # no-ops here since there is no JavaScript to handle their click.
        return button unless submit_button?(button)

        submit_form(finder.form_for(button), submitter: button)
      end

      def submit_form(form, submitter: nil)
        raise InvalidFormError, "element is not inside a form" if form.nil?

        result = FormSubmission.new(form, submitter, @config).submit!
        @trace&.__internal_record_form(method: result[:method], url: result[:url], params: result[:params])
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

      # Round-trip the whole jar (for a persistent cookie store): #export_cookies
      # returns plain Hashes, #import_cookies restores them preserving host_only.
      def export_cookies = @cookie_jar.export
      def import_cookies(entries) = entries.each { |attrs| @cookie_jar.import!(attrs) }

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
        page_exchange.request(method, absolute_url, params: params, body: body, headers: headers)
      end

      # The HttpExchange bound to this page: it reads the live header store and
      # routes per-request observation back onto the page thread (record
      # last_request, fire request/response listeners). The exchange itself only
      # touches thread-safe / immutable collaborators, so the same primitive can
      # later run on a network worker with inbox-routed hooks instead.
      def page_exchange
        @page_exchange ||= HttpExchange.new(
          app: @app,
          config: @config,
          cookie_jar: @cookie_jar,
          headers: @headers,
          on_request: lambda { |env|
            @last_request = env
            @request_listeners.each { |cb| cb.call(env) }
          },
          on_response: lambda { |response|
            @response_listeners.each { |cb| cb.call(response) }
          }
        )
      end

      # One step of the joint back/forward traversal (see #back).
      def traverse_history(direction)
        target = direction == :back ? @history.back : @history.forward
        return nil unless target

        if target.window&.equal?(@current_window) && target.windex
          begin
            @history_traversing = true
            @current_window.history.__internal_go_to__(target.windex)
          ensure
            @history_traversing = false
          end
          @current_url = target.url
          @js_runtime&.drain
        else
          @navigation.revisit(target.url)
        end
        target.url
      end
      private :traverse_history

      # Build a worker-safe thunk that fetches `target` (already absolute) and
      # returns the Response, for the async-network path. Called on the page
      # thread: it enforces same-origin and captures a header snapshot here, then
      # hands back a Proc that a network worker runs through an HttpExchange
      # touching only thread-safe state. Per-request observation is routed back
      # onto the page thread via the scheduler inbox (so the Trace still sees
      # subresource network); reload bookkeeping is intentionally not touched
      # (a subresource fetch is not a navigation).
      def build_subresource_fetch_job(target, method:, headers: {}, body: nil, redirect: :follow)
        @navigation.check_same_origin!(target)
        exchange = build_worker_exchange
        lambda do
          @navigation.fetch_resolved(exchange, method, target, headers: headers, body: body, redirect: redirect)
        end
      end

      # Apply a final navigation response: update last_response, current_url,
      # the document (HTML only), and the history stack.
      def apply_navigation_response(response, final_url, push_history: true, replace: false)
        @last_response = response
        @current_url = final_url
        if response.html?
          @current_window = response.window
          # Set the geometry mode before scripts boot so the very first
          # getBoundingClientRect a framework calls already sees it.
          @current_window.approximate_layout = @approximate_layout if @approximate_layout
          # Fill external stylesheets before listeners (script boot /
          # DOMContentLoaded) run, so CSS-driven computed styles and :visible
          # are correct from the first observation.
          install_stylesheet_loading(@current_window) if load_stylesheets?
          # The history entry exists and the window-history sync is live
          # BEFORE scripts boot: Turbo's replaceState-on-start then lands on
          # THIS entry, and its pushState navigations append after it.
          windex = @current_window.history.__internal_index__
          if replace
            # location.replace() / reload() / a redirect: overwrite the current
            # entry's URL and rebind it to the new document (no new entry).
            @history.replace_current_url(final_url)
            @history.rebind_current(window: @current_window, windex: windex)
          elsif push_history
            @history.push(final_url, window: @current_window, windex: windex)
          else
            # A revisit re-loaded this URL into a fresh document: re-bind the
            # existing entry so traversal sync matches the live window.
            @history.rebind_current(window: @current_window, windex: windex)
          end
          install_history_sync(@current_window)
          @document_loaded_listeners.each { |cb| cb.call(@current_window) }
        elsif replace
          @history.replace_current_url(final_url)
        elsif push_history
          @history.push(final_url)
        end
      end

      # Mirror the page's same-document history operations (Turbo Drive's
      # pushState navigations, JS history.back()) into the session: the joint
      # history gains/updates entries and current_url follows, so
      # `browser.current_path` and `browser.back` see what a browser's URL
      # bar and back button would. Guarded against echo while the session
      # itself drives a traversal, and against a stale window — a retained
      # handle to a navigated-away page must not touch the session's state.
      def install_history_sync(window)
        window.history.__internal_on_change__ = lambda do |kind, url|
          next if @history_traversing
          next unless window.equal?(@current_window)

          @current_url = url
          case kind
          when :push
            @history.push(url, window: window, windex: window.history.__internal_index__)
          when :replace
            @history.replace_current_url(url)
          when :traverse
            @history.sync_to(window, window.history.__internal_index__)
          end
        end
      end

      # Wire same-origin CSS loading for a freshly installed document: fill
      # <link rel=stylesheet> sheets eagerly and register an @import resolver
      # (pulled lazily when the cascade hits an @import).
      def install_stylesheet_loading(window)
        load_document_stylesheets(window)
        document = window&.document
        document.css_import_resolver = ->(url) { fetch_stylesheet_text(url) } if document
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
        __flush_page_navigation__
      end

      private

      # An HttpExchange for a network worker: it reads only thread-safe /
      # immutable state (a detached header snapshot, the frozen Config, the
      # thread-safe CookieJar, the stateless app). Request/response observation
      # is posted to the scheduler inbox so listeners (the Trace) still fire on
      # the page thread; last_request is deliberately left untouched off-thread.
      def build_worker_exchange
        sched = @current_window&.scheduler
        HttpExchange.new(
          app: @app,
          config: @config,
          cookie_jar: @cookie_jar,
          headers: @headers.snapshot,
          on_request: sched && lambda { |env|
            sched.post_external { @request_listeners.each { |cb| cb.call(env) } }
          },
          on_response: sched && lambda { |response|
            sched.post_external { @response_listeners.each { |cb| cb.call(response) } }
          }
        )
      end

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

      # Carry out a page-initiated navigation recorded by the delegate: resolve
      # the target, skip non-http(s) schemes (javascript:/mailto:/data:) and a
      # bare same-page fragment link, then navigate — folding form params into
      # the query (GET) or body (POST) as usual.
      def perform_page_navigation(nav)
        target = resolve_document_url(nav[:url])
        return unless %w[http https].include?(uri_scheme(target))
        return if nav[:params].nil? && same_page_fragment?(target)

        method = (nav[:method] || "GET").to_s.upcase
        params = nav[:params]
        method, params = apply_delegate_method_override(method, params) if params
        navigate(method: method, url: target, params: params, body: nav[:body],
                 headers: referer_headers, replace: nav[:replace])
      end

      # The delegate path serializes forms through core FormSubmission, which
      # doesn't know the session's method-override policy; apply it here so a
      # Rails `_method` hidden field turns a POST into PATCH/PUT/DELETE even for
      # an app without Rack::MethodOverride — matching the non-delegate submit.
      def apply_delegate_method_override(method, params)
        return [method, params] unless method == "POST" && @config.respect_method_override

        pairs = params.dup
        i = pairs.index { |name, _| name == @config.method_override_param }
        return [method, params] unless i

        override = pairs.delete_at(i)[1].to_s.upcase
        %w[PATCH PUT DELETE].include?(override) ? [override, pairs] : [method, params]
      end

      def uri_scheme(url)
        URI.parse(url).scheme.to_s.downcase
      rescue URI::InvalidURIError
        ""
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
        case button.tag_name
        when "BUTTON" then button.type == "submit"
        when "INPUT" then %w[submit image].include?(button.type)
        else false
        end
      end

    end
  end
end
