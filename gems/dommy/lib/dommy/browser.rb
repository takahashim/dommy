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

    # Raised in strict mode when JS errors were collected and not acknowledged.
    class JsError < StandardError
      attr_reader :causes

      def initialize(causes)
        @causes = causes
        super(build_message(causes))
      end

      private

      def build_message(causes)
        lines = causes.map { |e| "  #{e.class}: #{e.message}" }
        "#{causes.length} uncaught JS error(s):\n#{lines.join("\n")}"
      end
    end

    attr_reader :window, :runtime, :js_errors, :console

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
      wasm_memory_shim: false, backend: nil, navigable: false)
      @resources = resources
      @strict = strict
      @backend = backend
      @execute_scripts = execute_scripts
      @settle_after_boot = settle
      @wasm_memory_shim = wasm_memory_shim
      @navigable = navigable
      @js_errors = []
      @console = []
      @acknowledged = 0
      @allow_errors = false
      @disposed = false
      @pending_navigation = nil
      @runtime = nil

      @window = Dommy.parse(html)
      @window.location.__internal_set_url__(url) if url
      install_runtime(@window)

      if navigable
        @fetcher = Navigation::Fetcher.new(@resources)
        @history = Navigation::JointHistory.new
        @window.navigation_delegate = self
        @history.push(current_url, window: @window, windex: @window.history.__internal_index__)
      end
      check_js_errors!
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

      @pending_navigation = {url: url.to_s, method: "GET", source: :visit, replace: replace}
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
    def back = traverse(-1)
    def forward = traverse(1)

    # --- NavigationDelegate port (see Dommy::Navigation) ---

    # A cross-document navigation intent (link / form / location). Navigation is
    # a task: rather than swap the Window + JS realm synchronously (which may run
    # while the outgoing realm's JS is still on the stack — e.g. `location.href =`
    # inside a script), record it and perform the fetch + swap at the next drain
    # boundary (settle / after_interaction / advance_time). Ruby-initiated visits
    # flush immediately since no JS is on the stack.
    def navigate(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, headers: {}, replace: false)
      @pending_navigation = {
        url: url, method: method, body: body, params: params, enctype: enctype,
        headers: headers, replace: replace, source: source
      }
      nil
    end

    # A cross-document history traversal. Ruby-initiated (back / forward), so it
    # runs immediately: a same-document target (its window is still live)
    # traverses in place (popstate); a document-boundary target is re-fetched.
    def traverse(delta)
      return self unless @navigable

      entry = delta.negative? ? @history.back : @history.forward
      return self unless entry

      if entry.window && entry.window.equal?(@window)
        @window.history.__internal_go_to__(entry.windex)
        @runtime.drain_microtasks
        check_js_errors!
      else
        perform_navigation!({url: entry.url, method: "GET", source: :traverse}, rebind: true)
      end
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
      prevented = Dommy::Interaction::EventSynthesis.click(button)
      if !prevented && submit_button?(button) && (form = finder.form_for(button))
        # Centralized form submission (real SubmitEvent + delegate navigation);
        # a navigable browser thus follows an un-prevented submit for real.
        form.__run_form_submission__(button)
      end
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
    def allow_js_errors
      prev = @allow_errors
      @allow_errors = true
      yield
    ensure
      @allow_errors = prev
      @acknowledged = @js_errors.length
    end

    def dispose
      return if @disposed

      @disposed = true
      pending = unacknowledged
      @runtime&.dispose
      raise JsError, pending if @strict && !pending.empty?
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
      runtime = Js.build_runtime(@backend)
      runtime.on_unhandled_rejection { |err| @js_errors << err }
      runtime.on_callback_error { |err| @js_errors << err } if runtime.respond_to?(:on_callback_error)
      runtime.on_log { |log| @console << log }
      runtime.define_host_object("document", window.document)
      runtime.install_window(window)
      runtime.install_browser_globals
      # Opt-in WPT scaffolding (common/sab.js derives SharedArrayBuffer through
      # WebAssembly.Memory); off by default so real pages don't see the shim.
      runtime.install_wasm_memory_shim if @wasm_memory_shim && runtime.respond_to?(:install_wasm_memory_shim)
      window.globals["__fetch_handler__"] = Resources::FetchHandler.new(@resources) if @resources
      @runtime = runtime
      return unless @execute_scripts

      doc = window.document
      # Dynamically-inserted `<script src>` (webpack/Vite on-demand chunks)
      # fetch + run through the same resources adapter, after boot.
      doc.external_script_runner = lambda do |element, src|
        Js::ScriptBoot.run_external_script(runtime, doc, element, src,
          resources: @resources, on_error: ->(e) { @js_errors << e })
      end
      Js::ScriptBoot.run_document_scripts(
        runtime, doc, resources: @resources, on_error: ->(e) { @js_errors << e }
      )
      # Leave the page in a ready state: run on-load promises, due-now timers,
      # and rAF (not future timers). `settle: false` observes it mid-flight.
      runtime.settle if @settle_after_boot
    end

    # Perform a recorded navigation: fetch the target (following redirects),
    # fire the old document's unload, then replace the Window + JS realm with the
    # freshly parsed document and update the joint history. A network miss or a
    # non-document response leaves the current page in place.
    def perform_navigation!(nav, rebind: false)
      response, final_url = @fetcher.request(
        method: nav[:method] || "GET", url: nav[:url], params: nav[:params],
        body: nav[:body], enctype: nav[:enctype], headers: nav[:headers] || {}
      )
      return unless response&.success? && document_response?(response)

      # Fire the outgoing document's unload sequence while its realm is still
      # alive, then surface any of its errors before the realm is torn down.
      fire_unload(@window)
      check_js_errors!

      new_window = Dommy.parse(response.body)
      new_window.location.__internal_set_url__(final_url)
      new_window.navigation_delegate = self
      @window = new_window
      install_runtime(new_window)

      windex = new_window.history.__internal_index__
      if rebind || nav[:replace]
        @history.rebind_current(url: final_url, window: new_window, windex: windex)
      else
        @history.push(final_url, window: new_window, windex: windex)
      end
    end

    # Perform a pending navigation recorded by the delegate (JS-initiated
    # location.href= / form submit / link click). Called at drain boundaries so
    # the swap never runs with the outgoing realm's JS on the stack.
    def flush_navigation!
      return unless @navigable

      nav = @pending_navigation
      return unless nav

      @pending_navigation = nil
      perform_navigation!(nav)
    end

    def fire_unload(window)
      window.dispatch_event(Dommy::Event.new("pagehide"))
      window.dispatch_event(Dommy::Event.new("unload"))
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

    def unacknowledged = @js_errors[@acknowledged..] || []

    def submit_button?(button)
      if button.tag_name == "BUTTON"
        button.type == "submit"
      else
        %w[submit image].include?(button.type)
      end
    end

    # In strict mode, fail on any JS error collected since the last
    # acknowledgement. Marks all current errors acknowledged so each is reported
    # at most once.
    def check_js_errors!
      return if @allow_errors
      return unless @strict

      pending = unacknowledged
      return if pending.empty?

      @acknowledged = @js_errors.length
      raise JsError, pending
    end
  end
end
