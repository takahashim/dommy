# frozen_string_literal: true

module Dommy
  # A lightweight test browser: parse HTML, build window/document, run its
  # classic `<script>` tags (inline + external via a resources adapter), fire
  # DOMContentLoaded/load, and collect JS errors / console output. For
  # standalone HTML + JS (bundled SPA, fixture HTML); the Rack/Rails entry point
  # is `Dommy::Rack::Session` (a later phase).
  #
  #   Dommy::Browser.open(html, resources: Dommy::Resources.static("/app.js" => "...")) do |b|
  #     b.settle
  #     b.evaluate('document.querySelector("h1").textContent')
  #   end
  #
  # JS errors are not swallowed: in strict mode (default) any unhandled rejection
  # or uncaught script error fails at the next checkpoint (after boot, after
  # `settle`, at dispose). Wrap intentional errors in `allow_js_errors { … }`.
  class Browser
    # Capybara-vocabulary finding / scoping / field interaction / click /
    # matchers come from the shared interaction layer; each interaction's events
    # are dispatched Ruby-side (synchronously invoking JS handlers), then
    # `after_interaction` drains the runtime's microtasks so promise reactions
    # settle before the next line.
    include Dommy::Interaction::Driver

    attr_reader :window, :runtime, :console

    # The ledger of errors the page left unhandled (`Dommy::Js::ErrorLog`);
    # shared with the other hosts so strict mode behaves the same everywhere.
    attr_reader :error_log

    # The errors themselves, as a browser console's scrollback.
    def js_errors = @error_log.errors

    # Build a browser and (unless `execute_scripts: false`) boot its scripts. In
    # block form the browser is yielded and disposed afterward, returning the
    # block value.
    def self.open(html, **opts)
      browser = new(html, **opts)
      return browser unless block_given?

      begin
        yield browser
      ensure
        browser.dispose
      end
    end

    # Start a navigable session by fetching the initial document from
    # `resources`, rather than passing literal HTML. Links / forms / location
    # then perform real cross-document navigation (fetch → replace Window + JS
    # realm), with the browser handle (history, resources, error log) surviving.
    #   Dommy::Browser.visit("http://localhost/", resources: my_resources)
    def self.visit(url, resources:, **opts)
      browser = new("<!doctype html><html><head></head><body></body></html>",
        url: "about:blank", resources: resources, navigable: true, **opts)
      browser.visit(url, replace: true)
      browser
    end

    def initialize(html, url: "http://localhost/", resources: nil, execute_scripts: true, strict: true, settle: true,
      wasm_memory_shim: false, backend: nil, navigable: false, same_origin: false)
      @resources = resources
      @same_origin = same_origin
      @backend = backend
      @execute_scripts = execute_scripts
      @settle_after_boot = settle
      @wasm_memory_shim = wasm_memory_shim
      @navigable = navigable
      @error_log = Js::ErrorLog.new(strict: strict)
      @console = []
      @disposed = false
      @pending_navigations = []
      @runtime = nil
      # One browsing session: every window it shows (and their frames) shares
      # localStorage per origin and sessionStorage per origin.
      @storage_provider = StorageProvider.new
      @before_unload_handler = nil

      @window = Dommy.parse(html)
      @window.location.__internal_set_url__(url) if url
      @window.storage_provider = @storage_provider

      if navigable
        @fetcher = Navigation::Fetcher.new(@resources, same_origin: @same_origin)
        @history = Navigation::JointHistory.new
        @window.navigation_delegate = self
        @history.push(current_url, window: @window, windex: @window.history.__internal_index__)
        install_history_sync(@window)
      end
      install_runtime(@window)
      check_js_errors!
    end

    # The provider of this browser's Web Storage areas (shared by every window
    # it shows); see Dommy::StorageProvider.
    attr_reader :storage_provider

    # Install a handler for a page that asks to confirm leaving it (a canceled
    # `beforeunload`, or one whose returnValue is set): called with the window
    # and the BeforeUnloadEvent, its truthy answer lets the navigation proceed.
    # Without one the navigation always proceeds — a headless page has no sticky
    # user activation, so a browser would not prompt either.
    def on_before_unload(&block)
      @before_unload_handler = block
      self
    end

    def document = @window.document

    # Current document HTML (serialized).
    def html = @window.document.document_element&.outer_html

    # The current document's URL (the address bar).
    def current_url = @window.location.href

    # The joint (tab) history of a navigable browser, or nil for a plain
    # single-document browser.
    attr_reader :history

    # Programmatically navigate to `url` (a Ruby-initiated visit). Only
    # meaningful for a navigable browser; performs the fetch + document swap
    # immediately (there is no JS on the stack).
    def visit(url, replace: false)
      raise "browser is not navigable (use Browser.visit or navigable: true)" unless @navigable

      @pending_navigations << {url: url.to_s, method: "GET", source: :visit, replace: replace}
      flush_navigation!
      self
    end

    # Reload the current document (re-fetch, replace the current history entry).
    def reload
      visit(current_url, replace: true)
    end

    # Move back / forward one entry in the joint history. A same-document target
    # (the entry's window is still live) traverses in place (popstate); a
    # document-boundary target is re-fetched (no bfcache — D2).
    def back = traverse_now(-1)
    def forward = traverse_now(1)

    # --- NavigationDelegate port (see Dommy::Navigation) ---

    # A cross-document navigation intent (link / form / location). Navigation is
    # a task: rather than swap the Window + JS realm synchronously (which may run
    # while the outgoing realm's JS is still on the stack — e.g. `location.href =`
    # inside a script), record it and perform the fetch + swap at the next drain
    # boundary (settle / after_interaction / advance_time). Ruby-initiated visits
    # flush immediately since no JS is on the stack.
    def navigate(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, target: nil, headers: {}, replace: false)
      # A target that names an iframe in this document navigates that nested
      # browsing context. It can be performed now — it does not replace the top
      # realm — with only the frame's `load` deferred to a microtask, so a
      # listener installed right after `form.submit()` is registered first.
      frame = @navigable ? resolve_target_frame(target) : nil
      if frame
        navigate_frame(frame,
          {method: method, url: url, params: params, body: body, enctype: enctype, headers: headers},
          resolve_against_current(url.to_s))
        @window.scheduler.queue_microtask(proc { frame.dispatch_event(Dommy::Event.new("load")) })
        return nil
      end

      @pending_navigations << {
        url: url, method: method, body: body, params: params, enctype: enctype,
        target: target, headers: headers, replace: replace, source: source
      }
      nil
    end

    # A navigation delegate for an embedder-managed nested browsing context (an
    # iframe whose content document the host injected). A navigation from inside
    # that document loads into the frame itself.
    class FrameNavigationDelegate
      def initialize(browser, frame)
        @browser = browser
        @frame = frame
      end

      def navigate(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, target: nil, headers: {}, replace: false)
        @browser.__internal_load_frame__(@frame,
          {url: url, method: method, body: body, params: params, enctype: enctype, headers: headers})
      end

      def traverse(_delta) = nil

      def history_length = @browser.history_length
    end

    def frame_navigation_delegate(frame) = FrameNavigationDelegate.new(self, frame)

    # Load `nav` into `frame`, resolving the URL against the frame's own document,
    # then fire the frame's `load`. Public (an `__internal_` seam) so a host that
    # injected the frame's content document can wire it as that frame's delegate.
    def __internal_load_frame__(frame, nav)
      base = frame.content_window&.location&.__js_get__("href").to_s
      resolved = begin
        URI.join(base, nav[:url].to_s).to_s
      rescue URI::InvalidURIError, ArgumentError
        nav[:url].to_s
      end
      navigate_frame(frame, nav, resolved)
      frame.dispatch_event(Dommy::Event.new("load"))
      nil
    end

    # A history traversal by `delta` that the PAGE asked for (`history.go(n)`
    # past its own document's entries): like a navigation it is a task, so it
    # is recorded and performed at the next drain boundary.
    def traverse(delta)
      @pending_navigations << {traverse: delta.to_i} if @navigable
      nil
    end

    # `history.length`: the joint session history's size (nil when this
    # browser keeps none).
    def history_length = (@history.length if @navigable)

    # `window.stop()`: drop the navigations the page asked for and that have not
    # been performed yet.
    def stop
      @pending_navigations.clear
      nil
    end

    # A Ruby-initiated traversal (back / forward) runs immediately: a
    # same-document target (its window is still live) traverses in place
    # (popstate); a document-boundary target is re-fetched.
    def traverse_now(delta)
      return self unless @navigable

      perform_traversal!(delta)
      @runtime.drain_microtasks
      check_js_errors!
      self
    end

    # Evaluate an expression / statement body and return the decoded value.
    def evaluate(js)
      result = @runtime.evaluate(js)
      check_js_errors!
      result
    end

    # Run JS for side effects.
    def execute(js)
      @runtime.execute(js)
      check_js_errors!
      nil
    end

    # Settle the work ready at the current virtual time: drain microtasks, run
    # due-now timers, flush requestAnimationFrame. Does NOT fire a future
    # `setTimeout(300)` — use `advance_time(300)` for debounce/throttle.
    def settle
      @runtime.settle
      flush_navigation!
      check_js_errors!
      self
    end

    # Advance virtual time by `ms`, running timers that come due, then settle.
    def advance_time(ms)
      @window.scheduler.advance_time(ms)
      @runtime.drain_microtasks
      flush_navigation!
      check_js_errors!
      self
    end

    # An interaction's events have been dispatched (Ruby-side, synchronously
    # invoking JS handlers); drain the runtime's microtasks so promise reactions
    # land before the next line, then enforce strict mode.
    def after_interaction
      @runtime.drain_microtasks
      flush_navigation!
      check_js_errors!
    end

    # Click a submit-capable button. The button's click event fires (JS may
    # handle / preventDefault it); if it is an un-prevented submit button, the
    # owning form's submission algorithm runs (a real SubmitEvent a SPA can
    # intercept, then the delegate navigation). In a navigable browser that
    # follows the submit for real; otherwise the delegate just records it.
    def click_button(locator)
      button = finder.find_button(locator)
      # An un-prevented click runs the button's activation behavior — a submit
      # button submits its owning form (real SubmitEvent + delegate navigation),
      # so a navigable browser follows the submit for real.
      Dommy::Interaction::EventSynthesis.click(button)
      after_interaction
      button
    end

    # Click a link, firing its click event so SPA JS (Turbo, React Router, …)
    # can intercept. An un-prevented click runs the anchor's activation behavior
    # (follow-the-hyperlink); in a navigable browser that navigates for real,
    # otherwise the delegate records it.
    def click_link(locator)
      link = finder.find_link(locator)
      Dommy::Interaction::EventSynthesis.click(link)
      after_interaction
      link
    end

    # Suppress strict-mode failure for JS errors raised inside the block (they
    # stay collected in #js_errors for inspection). For tests that expect errors.
    def allow_js_errors(&block)
      @error_log.allow(&block)
    end

    # Tear the realm down, then fail on anything the page left unhandled and
    # nobody has reported. Disposing first means the failure cannot leave a live
    # VM behind.
    def dispose
      return if @disposed

      @disposed = true
      @runtime&.dispose
      @error_log.check!(context: current_url)
    end

    private

    # Build a fresh JS realm for `window`, wire error/console/fetch/external-
    # script seams, and boot its `<script>` tags. Disposes the previous realm
    # first (a no-op on the initial load), so a navigation tears the outgoing
    # realm — and with it every pending timer / microtask on the old Window's
    # scheduler — down before the new page runs.
    def install_runtime(window)
      @runtime&.dispose
      # The JS engine is pluggable: `@backend` selects a registered runtime
      # (nil → the configured default, QuickJS when dommy-js-quickjs is loaded).
      runtime = Js::ModulePreload.build_runtime(window.document, @backend)
      # Every uncaught error the page produces goes through the window's
      # "report an exception" / "notify about rejected promises" funnel, and only
      # what the page left unhandled lands here. A page that installs its own
      # `window.onerror` / `unhandledrejection` handler and cancels the event
      # suppresses the failure, exactly as it would in a browser.
      window.__internal_on_unhandled_error__ { |err| @error_log.record(err) }
      # A rejection the page handled after we reported it is retracted, so it
      # stops failing anything (WHATWG `rejectionhandled`).
      window.__internal_on_rejection_handled__ { |record| @error_log.retract(record) }
      runtime.on_unhandled_rejection { |err| report_rejection(window, err) }
      if runtime.respond_to?(:on_callback_error)
        runtime.on_callback_error { |err| Internal::ExceptionReport.report_at(window, err) }
      end
      runtime.on_log { |log| @console << log }
      runtime.define_host_object("document", window.document)
      runtime.install_window(window)
      runtime.install_browser_globals
      # Opt-in WPT scaffolding (common/sab.js derives SharedArrayBuffer through
      # WebAssembly.Memory); off by default so real pages don't see the shim.
      runtime.install_wasm_memory_shim if @wasm_memory_shim && runtime.respond_to?(:install_wasm_memory_shim)
      window.globals["__fetch_handler__"] = Resources::FetchHandler.new(@resources) if @resources
      @runtime = runtime
      doc = window.document
      # An `on*` attribute that arrived after boot (a cloned template, an
      # innerHTML fragment) is compiled on first dispatch, which replays the scan.
      # Installed whenever a runtime is attached — an embedder that drives script
      # boot itself (`execute_scripts: false`) still needs inline handlers wired.
      doc.inline_handler_wirer = lambda do
        Js::ScriptBoot.wire_inline_handlers(runtime, on_error: ->(e) { @error_log.record(e) })
      end
      return unless @execute_scripts

      # `on_error:` here is only the windowless fallback — a booted document has
      # a window, so a throwing script reports through it (see ScriptBoot).

      # Dynamically-inserted `<script src>` (webpack/Vite on-demand chunks)
      # fetch + run through the same resources adapter, after boot.
      doc.external_script_runner = lambda do |element, src|
        Js::ScriptBoot.run_external_script(runtime, doc, element, src,
          resources: @resources, on_error: ->(e) { @error_log.record(e) })
      end
      Js::ScriptBoot.run_document_scripts(
        runtime, doc, resources: @resources, on_error: ->(e) { @error_log.record(e) }
      )
      # Leave the page in a ready state: run on-load promises, due-now timers,
      # and rAF (not future timers). `settle: false` observes it mid-flight.
      runtime.settle if @settle_after_boot
    end

    # Route an unhandled promise rejection through the page's own
    # `unhandledrejection` handling first. The engine decides WHEN a rejection
    # counts as unhandled (see Window#__internal_report_rejection__).
    def report_rejection(window, error)
      value = Internal::ExceptionReport.error_value(error)
      window.__internal_report_rejection__(value, host_error: error)
    end

    # Perform a recorded navigation: fetch the target (following redirects),
    # fire the old document's unload, then replace the Window + JS realm with the
    # freshly parsed document and update the joint history. A network miss or a
    # non-document response leaves the current page in place.
    MAX_META_REFRESHES = 20

    def perform_navigation!(nav, rebind: false, refresh_depth: 0)
      # A form's action is a document-relative URL; resolve it against the
      # current address (links already arrive resolved via Location).
      resolved = resolve_against_current(nav[:url].to_s)
      # A `target` naming an iframe in this document navigates that nested
      # browsing context instead of replacing the top-level page.
      frame = resolve_target_frame(nav[:target])
      return navigate_frame(frame, nav, resolved) if frame

      # The outgoing page may ask to confirm leaving (beforeunload).
      return unless unloading_allowed?(@window)

      response, final_url = @fetcher.request(
        method: nav[:method] || "GET", url: resolved, params: nav[:params],
        body: nav[:body], enctype: nav[:enctype], headers: nav[:headers] || {}
      )
      return unless response&.success? && document_response?(response)

      old_window = @window
      referrer = referrer_for(nav[:source], old_window.location.href, final_url)
      # Fire the outgoing document's unload sequence while its realm is still
      # alive, then surface any of its errors before the realm is torn down.
      fire_unload(old_window)
      check_js_errors!

      new_window = Dommy.parse(response.body)
      new_window.location.__internal_set_url__(final_url)
      new_window.document.__internal_referrer__ = referrer if referrer
      new_window.navigation_delegate = self
      new_window.storage_provider = @storage_provider
      old_window.__internal_discard__
      @window = new_window

      windex = new_window.history.__internal_index__
      if rebind || nav[:replace]
        @history.rebind_current(url: final_url, window: new_window, windex: windex)
      else
        @history.push(final_url, window: new_window, windex: windex)
      end
      # The joint history knows the new page before its scripts boot, so a
      # pushState / history.length during boot sees the right session.
      install_history_sync(new_window)
      install_runtime(new_window)

      follow_meta_refresh!(refresh_depth)
    end

    # Fire `beforeunload` at the outgoing window; a page that cancels it (or
    # sets returnValue) is asked about through the on_before_unload handler, if
    # one is installed.
    def unloading_allowed?(window)
      event = BeforeUnloadEvent.new("beforeunload", "cancelable" => true).__internal_mark_trusted__
      not_canceled = window.dispatch_event(event)
      return true if not_canceled && event.return_value.to_s.empty?
      return true unless @before_unload_handler

      @before_unload_handler.call(window, event) ? true : false
    end

    # The `document.referrer` a navigation hands the new document: the page
    # that started it (links, forms, script), under the default
    # strict-origin-when-cross-origin policy — the full URL (without fragment
    # or credentials) within an origin, only the origin across origins, nothing
    # on an https -> http downgrade. Ruby-initiated visits and traversals carry
    # none.
    def referrer_for(source, from_url, to_url)
      return nil unless %i[link form location window_open].include?(source)

      from = URL.new(from_url.to_s)
      to = URL.new(to_url.to_s)
      return nil unless %w[http: https:].include?(from.protocol)
      return "" if from.protocol == "https:" && to.protocol == "http:"
      return "#{from.origin}/" unless from.origin == to.origin

      from.hash = ""
      from.username = ""
      from.password = ""
      from.href
    rescue StandardError
      nil
    end

    # A traversal by `delta` of the joint history: within the live window's own
    # entries it moves that window's history (popstate); across a document
    # boundary the target entry's URL is re-fetched (no bfcache).
    def perform_traversal!(delta)
      entry = @history.go(delta)
      return unless entry

      if entry.window && entry.window.equal?(@window)
        @window.history.__internal_go_to__(entry.windex)
      else
        perform_navigation!({url: entry.url, method: "GET", source: :traverse}, rebind: true)
      end
    end

    # Mirror the page's same-document history changes (pushState, fragment
    # navigations, its own back/forward within the document) into the joint
    # history, so Browser#back and history.length see them. Guarded against a
    # navigated-away window.
    def install_history_sync(window)
      window.history.__internal_on_change__ = lambda do |kind, url|
        next unless window.equal?(@window)

        case kind
        when :push
          @history.push(url, window: window, windex: window.history.__internal_index__)
        when :replace
          @history.rebind_current(url: url, window: window, windex: window.history.__internal_index__)
        when :traverse
          @history.sync_to(window, window.history.__internal_index__)
        end
      end
    end

    # The reserved browsing-context keywords; anything else names an iframe.
    RESERVED_TARGETS = %w[_self _top _parent _blank].freeze

    # The iframe a `target` names in the current document, or nil when the
    # target is empty / a reserved keyword / names no frame (then the navigation
    # is top-level, the only context Dommy models).
    def resolve_target_frame(target)
      name = target.to_s
      return nil if name.empty? || RESERVED_TARGETS.include?(name.downcase)

      @window.document.query_selector_all("iframe").find do |frame|
        frame.__internal_attribute_value__("name").to_s == name
      end
    end

    # Load a navigation into a nested browsing context (a named iframe): fetch
    # it, install the response document as the frame's content, and fire the
    # frame's `load`. The top-level window and joint history are left alone.
    def navigate_frame(frame, nav, resolved_url)
      response, final_url = @fetcher.request(
        method: nav[:method] || "GET", url: resolved_url, params: nav[:params],
        body: nav[:body], enctype: nav[:enctype], headers: nav[:headers] || {}
      )
      return unless response&.success?

      sub_window = frame_document_for(response)
      sub_window.location.__internal_set_url__(final_url)
      # A navigation from inside the loaded frame also stays in that frame.
      sub_window.navigation_delegate = frame_navigation_delegate(frame)
      # A nested realm needs the seeded constructors to run the response's
      # scripts; a runtime that cannot expose them simply runs without them.
      @runtime.expose_constructors_on(sub_window) if @runtime.respond_to?(:expose_constructors_on)
      frame.__internal_set_content_document__(sub_window.document)
      nil
    end

    # The document a frame shows for a response: HTML/XML is parsed as-is; a
    # non-document response (e.g. text/plain from an echo endpoint) is displayed
    # as text, so the frame gets a document whose body holds it.
    def frame_document_for(response)
      return Dommy.parse(response.body) if document_response?(response)

      win = Dommy.parse("<!doctype html><html><head></head><body></body></html>")
      win.document.body.text_content = response.body.to_s.dup.force_encoding(Encoding::UTF_8)
      win
    end

    # If the freshly loaded document asks for an immediate `<meta http-equiv=
    # refresh>`, follow it (as a replace, like a redirect), capped so a page that
    # refreshes to itself can't loop forever.
    def follow_meta_refresh!(depth)
      return if depth >= MAX_META_REFRESHES

      target = meta_refresh_target(@window.document)
      return unless target

      perform_navigation!({url: target, method: "GET", source: :meta_refresh},
        rebind: true, refresh_depth: depth + 1)
    end

    # The resolved URL a `<meta http-equiv="refresh" content="0; url=…">` points
    # at, or nil when the document has none (or a refresh with no URL, which just
    # reloads and is left alone to avoid a busy loop).
    def meta_refresh_target(document)
      document.query_selector_all("meta").each do |meta|
        next unless meta.__internal_attribute_value__("http-equiv").to_s.casecmp?("refresh")

        _delay, separator, rest = meta.__internal_attribute_value__("content").to_s.partition(";")
        next if separator.empty?

        url = rest.strip.sub(/\Aurl\s*=\s*/i, "").gsub(/\A["']|["']\z/, "").strip
        return resolve_against_current(url) unless url.empty?
      end
      nil
    end

    def resolve_against_current(url)
      URI.join(current_url, url).to_s
    rescue URI::InvalidURIError
      url
    end

    # Perform a pending navigation recorded by the delegate (JS-initiated
    # location.href= / form submit / link click). Called at drain boundaries so
    # the swap never runs with the outgoing realm's JS on the stack.
    def flush_navigation!
      return unless @navigable
      return if @pending_navigations.empty?

      navs = @pending_navigations
      @pending_navigations = []
      navs.each do |nav|
        nav.key?(:traverse) ? perform_traversal!(nav[:traverse]) : perform_navigation!(nav)
      end
    end

    # Unload the outgoing document: `pagehide` (a PageTransitionEvent, persisted
    # false), then `unload` — both trusted and targeted at the document.
    def fire_unload(window)
      document = window.document
      window.dispatch_event(document.__internal_page_transition_event__("pagehide"))
      unload = Dommy::Event.new("unload")
      unload.__internal_set_target__(document)
      window.dispatch_event(unload.__internal_mark_trusted__)
    end

    # Only HTML/XML responses replace the document; other content types (a JSON
    # API hit, an image) leave the current page. A response with no Content-Type
    # is treated as a document (fixtures commonly omit it).
    def document_response?(response)
      headers = response.headers || {}
      key = headers.keys.find { |k| k.to_s.casecmp?("content-type") }
      content_type = key ? headers[key].to_s.downcase : ""
      content_type.empty? || content_type.include?("html") || content_type.include?("xml")
    end

    def submit_button?(button)
      if button.tag_name == "BUTTON"
        button.type == "submit"
      else
        %w[submit image].include?(button.type)
      end
    end

    # In strict mode, fail on anything the page left unhandled since the last
    # checkpoint. The ledger drains itself, so each error is reported once.
    def check_js_errors!
      @error_log.check!(context: current_url)
    end
  end
end
