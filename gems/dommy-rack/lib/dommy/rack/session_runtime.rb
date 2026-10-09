# frozen_string_literal: true

module Dommy
  module Rack
    # Binds a JS runtime to a Session: each HTML document the session loads gets
    # its own JS realm (window globals, listeners, timers), its `<script>` tags
    # boot, and window.fetch / external scripts resolve through the session's
    # Rack app (shared cookie jar). Subscribes to the session's
    # `on_document_loaded` seam so VM lifetime follows page loads.
    #
    # The JS engine is pluggable: realms are built through
    # `Dommy::Js.build_runtime`, so any registered backend (QuickJS via
    # dommy-js-quickjs, others later) drives the session. This is the engine
    # behind `Dommy::Rack::Session.new(app, javascript: true)` and the Capybara
    # driver's JS support — one realm manager, two front ends.
    class SessionRuntime
      PUMP_SLICE_MS = 50

      # `current_document` yields the document execute/evaluate should target
      # (the session's current document by default; the Capybara driver passes
      # its own frame-aware accessor).
      # Console output collected across every realm.
      attr_reader :console

      # The ledger of errors the page left unhandled, across every realm. The
      # Session drives its checkpoints; see Dommy::Js::ErrorLog.
      attr_reader :error_log

      def initialize(session, &current_document)
        @session = session
        @current_document = current_document || -> { session.document }
        @runtimes = {}.compare_by_identity
        # Non-strict by default: an embedding browser only reads the errors. A
        # test front end turns strictness on through the owning Session, which
        # is also what drives the checkpoints.
        @error_log = ::Dommy::Js::ErrorLog.new(strict: false)
        @console = []
        @console_listeners = []
        @js_error_listeners = []
        @script_listeners = []
        @document_listeners = []
        session.on_document_loaded { |window| on_page_load(window) }
      end

      # Observation seams a Trace (or other host) subscribes to. console output,
      # JS errors, and script-boot results are realm-internal — they surface
      # here, not on the Session — so the runtime fans them out. `on_document`
      # fires before a freshly loaded page's scripts boot (see on_page_load), so
      # a `:document` marker is ordered ahead of that page's `:script` entries.
      # Uncaught JS errors and unhandled promise rejections the page did not
      # handle, as a browser console's scrollback (cleared on navigation).
      def js_errors = @error_log.errors

      def on_console(&block) = @console_listeners << block
      def on_js_error(&block) = @js_error_listeners << block
      def on_script(&block) = @script_listeners << block
      def on_document(&block) = @document_listeners << block

      def execute(js) = current_runtime.execute(js)
      def evaluate(js) = current_runtime.evaluate(js)

      # Args-aware variants: the runtime must implement the optional
      # execute_with_args / evaluate_with_args (dommy-js-quickjs does). Callers
      # guard with respond_to? and fall back to the no-arg form.
      def execute_with_args(js, args) = current_runtime.execute_with_args(js, args)
      def evaluate_with_args(js, args) = current_runtime.evaluate_with_args(js, args)

      def supports_script_args? = current_runtime.respond_to?(:execute_with_args)

      # Settle work ready at the current virtual time (microtasks + due-now
      # timers + rAF) for the current document's realm.
      def settle
        current_runtime.settle
        self
      end

      # Advance the page's virtual clock: every live realm's (the top window's
      # and its frames'), which move together as one page's time does, running
      # the timers that come due and the completions handed back, then
      # draining each realm's microtasks. Snapshot iteration: a fired timer
      # may navigate and replace the map.
      def advance_time(ms)
        @runtimes.to_a.each do |doc, runtime|
          scheduler_of(doc)&.advance_time(ms)
          runtime.drain_microtasks
        end
        self
      end

      # Drain the current realm's microtasks (used as an interaction's settle
      # point: a Ruby-dispatched event ran JS handlers; flush their promises).
      def drain
        current_runtime.drain_microtasks
        self
      end

      # Advance the page's clock a slice (dommy-js-quickjs's legacy Capybara
      # adapter polls with it).
      def pump = advance_time(PUMP_SLICE_MS)

      # The current realm's virtual clock, in ms.
      def now_ms = scheduler_of(@current_document.call)&.now_ms

      # The virtual ms until the page's next timer (setTimeout, setInterval,
      # requestAnimationFrame) in any realm is due — 0 for one due already —
      # or nil when none is scheduled.
      def next_timer_delay
        @runtimes.each_key.filter_map do |doc|
          scheduler = scheduler_of(doc)
          due = scheduler&.next_due_timer_at
          due && [due - scheduler.now_ms, 0].max
        end.min
      end

      # Whether a completion another thread handed back (a response, a socket
      # message) waits to be delivered to any realm.
      def external_pending?
        @runtimes.each_key.any? { |doc| scheduler_of(doc)&.external_pending? }
      end

      # Whether any realm has handed work to a worker (a fetch on the network
      # executor) that has not come back yet.
      def external_work_in_flight?
        @runtimes.each_key.any? { |doc| scheduler_of(doc)&.external_work_in_flight? }
      end

      # The realm VM for one document, built lazily and cached by identity so a
      # frame switch keeps each realm's JS state instead of rebuilding it.
      def runtime_for(doc)
        @runtimes[doc] ||= build_runtime(doc)
      end

      def current_runtime
        runtime_for(@current_document.call)
      end

      def dispose
        dispose_all
      end

      private

      # The deterministic scheduler driving a document's realm (nil when the
      # document or its window is absent), keeping the `doc -> window ->
      # scheduler` walk in one place.
      def scheduler_of(doc)
        doc&.default_view&.scheduler
      end

      # A top-level navigation invalidates every realm (the old documents are
      # gone): dispose all, then eagerly build the new top realm so its
      # window / fetch bridge are live before any script runs.
      def on_page_load(window)
        # Scope js_errors / console to the page being loaded — a browser's console
        # clears on navigation. Cleared BEFORE the new realm boots so this page's
        # own boot errors are retained. (An embedder that wants a running history
        # keeps its own log; e.g. dommynx drains each page's output into its
        # activity log before the next navigation.) Cleared in place so the Trace's
        # separate live feed is unaffected. Only the HISTORY goes: an error this
        # page produced that nobody has reported yet still has to fail the test,
        # so the ledger's unacknowledged queue survives the navigation.
        @error_log.clear_history
        @console.clear
        dispose_all
        # Announce the document BEFORE booting its scripts so a subscriber (the
        # Trace) records the `:document` marker ahead of the `:script` entries
        # that build_runtime emits during boot.
        @document_listeners.each { |cb| cb.call(window) }
        runtime_for(window.document)
      end

      def build_runtime(doc)
        rt = Dommy::Js::ModulePreload.build_runtime(doc)
        window = doc&.default_view
        # Uncaught errors and unhandled rejections reach us through the window's
        # WHATWG report funnel, so the page's own `window.onerror` /
        # `unhandledrejection` handlers get first refusal — only what it leaves
        # unhandled is recorded, like a browser console. A document with no
        # window (nothing to report to) records directly.
        if window
          window.__internal_on_unhandled_error__ { |err| record_js_error(err) }
            # A rejection the page handled after we reported it is retracted, so it
            # stops failing anything (WHATWG `rejectionhandled`).
            window.__internal_on_rejection_handled__ { |record| @error_log.retract(record) }
          rt.on_unhandled_rejection { |err| report_rejection(window, err) }
          if rt.respond_to?(:on_callback_error)
            rt.on_callback_error { |err| ::Dommy::Internal::ExceptionReport.report_at(window, err) }
          end
        else
          rt.on_unhandled_rejection { |err| record_js_error(err) }
          rt.on_callback_error { |err| record_js_error(err) } if rt.respond_to?(:on_callback_error)
        end
        rt.on_log { |log| record_console(log) }
        rt.define_host_object("document", doc)
        if window
          rt.install_window(window)
          rt.install_browser_globals
          # Page-initiated navigations (JS location.href=, form submit, activated
          # <a>) route through the core NavigationDelegate port to the session,
          # which defers and performs them at the next drain.
          window.navigation_delegate = @session.__internal_navigation_delegate_for__(window)
          resources = ::Dommy::Rack::Resources.new(@session)
          # Off-thread network is opt-in: with a session executor, fetch / XHR
          # resolve through a DeferredResponse on this window's scheduler;
          # without one the handler stays synchronous.
          ::Dommy::Rack::NetworkBridge.install(
            @session, window, resources: resources, executor: @session.network_executor, scheduler: window.scheduler
          )
          # Same-origin WebSockets connect to the Rack app itself (ActionCable
          # et al.); cross-origin ones keep the in-memory stub.
          window.websocket_connector = @session.__internal_websocket_connector(window)
          # Same-origin EventSources stream from the Rack app itself; cross-origin
          # ones keep the in-memory stub (see EventSourceTransport).
          window.event_source_connector = @session.__internal_event_source_connector(window)
          # Dynamically-inserted `<script src>` (webpack/Vite on-demand chunks)
          # fetch + run through the same resources adapter, after boot.
          doc.external_script_runner = lambda do |element, src|
            ::Dommy::Js::ScriptBoot.run_external_script(
              rt, doc, element, src, resources: resources, on_error: ->(e) { record_js_error(e) }
            )
            @script_listeners.each { |cb| cb.call(element, nil) }
          end
          # Warm the cache by downloading the document's <script src> bundles
          # concurrently BEFORE the boot below runs them one by one — the dominant
          # cost of a heavy SPA's first paint is fetching a dozen big bundles
          # sequentially. No-op without a network executor.
          resources.prefetch(external_script_srcs(doc))
          ::Dommy::Js::ScriptBoot.run_document_scripts(
            rt, doc, resources: resources,
            on_script: ->(element, error) { @script_listeners.each { |cb| cb.call(element, error) } }
          )
        end
        rt
      end

      # The `src` of every external script in the freshly parsed document, for
      # concurrent prewarming. Resources resolves/filters them (origin gate); we
      # just hand over the raw attribute values.
      def external_script_srcs(doc)
        return [] unless doc.respond_to?(:query_selector_all)

        doc.query_selector_all("script[src]").filter_map { |el| el.get_attribute("src") }
      end

      def dispose_all
        @runtimes.each_value(&:dispose)
        @runtimes = {}.compare_by_identity
      end

      # Route an unhandled promise rejection through the page's own
      # `unhandledrejection` handling first.
      def report_rejection(window, error)
        value = ::Dommy::Internal::ExceptionReport.error_value(error)
        window.__internal_report_rejection__(value, host_error: error)
      end

      # Collect a JS error / console log into the cross-realm streams and fan it
      # out to any registered observers (the Trace).
      def record_js_error(err)
        @error_log.record(err)
        @js_error_listeners.each { |cb| cb.call(err) }
      end

      def record_console(log)
        @console << log
        @console_listeners.each { |cb| cb.call(log) }
      end
    end
  end
end
