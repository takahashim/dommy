# frozen_string_literal: true

require "uri"
require "json"
require "tmpdir"

module Dommy
  module Rack
    # A single browser-like session over a Rack application. Owns the current
    # URL, document, cookie jar, and history; delegates URL/redirect logic to
    # Navigation and form data collection to FormSubmission.
    class Session
      DEFAULT_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

      Config = Struct.new(
        :default_host, :follow_redirects, :max_redirects,
        :respect_method_override, :method_override_param,
        :user_agent, :accept, :enforce_same_origin, :follow_meta_refresh,
        keyword_init: true
      )

      attr_reader :last_request, :last_response, :history

      def initialize(app,
                     default_host: "http://example.org",
                     follow_redirects: true,
                     max_redirects: 5,
                     respect_method_override: true,
                     method_override_param: "_method",
                     user_agent: "DommyRack",
                     accept: DEFAULT_ACCEPT,
                     enforce_same_origin: true,
                     follow_meta_refresh: true)
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
          follow_meta_refresh: follow_meta_refresh
        ).freeze
        @cookie_jar = CookieJar.new
        @navigation = Navigation.new(self)
        @history = History.new
        @current_url = nil
        @current_window = nil
        @last_request = nil
        @last_response = nil
        @default_headers = {}
        @scope_stack = []
        @request_listeners = []
        @response_listeners = []
      end

      # --- Config readers used by collaborators ---

      def default_host = @config.default_host
      def follow_redirects? = @config.follow_redirects
      def max_redirects = @config.max_redirects
      def enforce_same_origin? = @config.enforce_same_origin
      def follow_meta_refresh? = @config.follow_meta_refresh
      def config = @config

      # --- Navigation API ---

      def visit(path)
        @navigation.navigate(method: "GET", url: path)
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
      def default_headers = @default_headers.dup

      def set_header(name, value)
        @default_headers[name.to_s] = value.to_s
        self
      end

      def delete_header(name)
        target = name.to_s.downcase
        @default_headers.delete_if { |key, _| key.downcase == target }
        self
      end

      # HTTP Basic auth: sets a persistent Authorization header.
      def basic_auth(user, password)
        set_header("Authorization", "Basic #{["#{user}:#{password}"].pack("m0")}")
      end

      # Bearer-token auth: sets a persistent Authorization header.
      def authorization_bearer(token)
        set_header("Authorization", "Bearer #{token}")
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

      # Restrict element finds and matchers to within the first element
      # matching `selector` for the duration of the block.
      def within(selector, &block)
        node = scope_root&.query_selector(selector)
        raise ElementNotFoundError, "no element matching #{selector.inspect}" unless node

        with_scope(node, &block)
      end

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

      def has_css?(selector, count: nil)
        nodes = scope_root ? scope_root.query_selector_all(selector) : []
        count ? nodes.size == count : !nodes.empty?
      end

      def has_no_css?(selector, count: nil) = !has_css?(selector, count: count)

      def has_text?(string)
        scope_text.include?(string.to_s)
      end

      def has_no_text?(string) = !has_text?(string)

      def has_link?(locator) = element_present? { finder.find_link(locator) }
      def has_button?(locator) = element_present? { finder.find_button(locator) }
      def has_field?(locator) = element_present? { finder.find_field(locator) }

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

      def fill_in(locator, with:)
        field = finder.find_field(locator)
        field.value = with.to_s
        field
      end

      def choose(locator)
        radio = finder.find_field(locator)
        clear_radio_group(radio)
        radio.checked = true
        radio
      end

      def check(locator)
        box = finder.find_field(locator)
        box.checked = true
        box
      end

      def uncheck(locator)
        box = finder.find_field(locator)
        box.checked = false
        box
      end

      def attach_file(locator, path)
        input = finder.find_field(locator)
        raise FileNotFoundError, "no such file: #{path}" unless ::File.exist?(path)

        file = Dommy::File.new(
          [::File.binread(path)], ::File.basename(path), "type" => FileUpload.mime_type_for(path)
        )
        input.__driver_set_files__([file])
        input
      end

      def select(value, from:)
        select_el = finder.find_field(from)
        option = finder.find_option(select_el, value)
        raise ElementNotFoundError, "no option #{value.inspect} in #{from.inspect}" unless option

        select_el.options.each { |o| o.remove_attribute("selected") } unless select_el.multiple
        option.set_attribute("selected", "")
        select_el
      end

      def unselect(value, from:)
        select_el = finder.find_field(from)
        option = finder.find_option(select_el, value)
        option&.remove_attribute("selected")
        select_el
      end

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
          headers: merge_headers(@default_headers, headers),
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
        @current_window = response.window if response.html?
        @history.push(final_url) if push_history
      end

      private

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

      # A Locator bound to the current scope (document, or the innermost
      # #within / #within_frame node), for finding elements.
      def finder
        Locator.new(scope_root)
      end

      # The node element finds and matchers query against: the innermost active
      # scope, or the document when none is open.
      def scope_root
        @scope_stack.last || document
      end

      # Push `node` as the active scope for the block, always restoring the
      # previous scope afterward. Returns the block value, or the node itself
      # when no block is given.
      def with_scope(node)
        @scope_stack.push(node)
        begin
          block_given? ? yield(self) : node
        ensure
          @scope_stack.pop
        end
      end

      # Visible text of the current scope. Documents expose text via <body>;
      # elements expose it directly.
      def scope_text
        root = scope_root
        return "" unless root
        return root.body&.text_content.to_s if root.respond_to?(:body) # document-like

        root.respond_to?(:text_content) ? root.text_content.to_s : ""
      end

      # True if the block finds an element. A unique match or an ambiguous
      # match both count as present; only "not found" counts as absent.
      def element_present?
        yield
        true
      rescue ElementNotFoundError
        false
      rescue AmbiguousElementError
        true
      end

      # Locate an iframe by id, name attribute, or CSS selector; the sole frame
      # in scope when no locator is given.
      def find_frame(locator)
        return scope_root&.query_selector("iframe, frame") if locator.nil?

        scope_root&.get_element_by_id(locator) ||
          scope_root&.query_selector("iframe[name='#{locator}'], frame[name='#{locator}']") ||
          scope_root&.query_selector(locator)
      end

      # Merge request headers case-insensitively; per-request values override
      # persistent defaults even when the names differ only in case.
      def merge_headers(base, override)
        return base.dup if override.nil? || override.empty?

        merged = base.dup
        override.each do |name, value|
          merged.delete_if { |existing, _| existing.to_s.downcase == name.to_s.downcase }
          merged[name] = value
        end
        merged
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

      def clear_radio_group(radio)
        name = radio.get_attribute("name")
        return unless name

        scope = radio.closest("form") || document
        scope.query_selector_all("input[type='radio']").each do |r|
          r.checked = false if r.get_attribute("name") == name
        end
      end
    end
  end
end
