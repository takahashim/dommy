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
      # Uncaught JS errors and unhandled promise rejections collected across
      # every realm (a host can fail a test when non-empty), and console output.
      attr_reader :js_errors, :console

      def initialize(session, &current_document)
        @session = session
        @current_document = current_document || -> { session.document }
        @runtimes = {}.compare_by_identity
        @js_errors = []
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
      def on_console(&block) = @console_listeners << block
      def on_js_error(&block) = @js_error_listeners << block
      def on_script(&block) = @script_listeners << block
      def on_document(&block) = @document_listeners << block

      def execute(js) = current_runtime.execute(js)
      def evaluate(js) = current_runtime.evaluate(js)

      # Settle work ready at the current virtual time (microtasks + due-now
      # timers + rAF) for the current document's realm.
      def settle
        current_runtime.settle
        self
      end

      # Advance the current realm's virtual clock, running timers that come
      # due, then drain.
      def advance_time(ms)
        scheduler_of(@current_document.call)&.advance_time(ms)
        current_runtime.drain_microtasks
        self
      end

      # Drain the current realm's microtasks (used as an interaction's settle
      # point: a Ruby-dispatched event ran JS handlers; flush their promises).
      def drain
        current_runtime.drain_microtasks
        self
      end

      # Advance virtual time a slice and drain across EVERY live realm, so a
      # timer in any window (top or frame) progresses while a poller waits.
      # Snapshot iteration: a fired timer may navigate and replace the map.
      def pump
        @runtimes.to_a.each do |doc, runtime|
          scheduler_of(doc)&.advance_time(PUMP_SLICE_MS)
          runtime.drain_microtasks
        end
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
        # separate live feed is unaffected.
        @js_errors.clear
        @console.clear
        dispose_all
        # Announce the document BEFORE booting its scripts so a subscriber (the
        # Trace) records the `:document` marker ahead of the `:script` entries
        # that build_runtime emits during boot.
        @document_listeners.each { |cb| cb.call(window) }
        runtime_for(window.document)
      end

      def build_runtime(doc)
        rt = Dommy::Js.build_runtime
        rt.on_unhandled_rejection { |err| record_js_error(err) }
        rt.on_callback_error { |err| record_js_error(err) } if rt.respond_to?(:on_callback_error)
        rt.on_log { |log| record_console(log) }
        rt.define_host_object("document", doc)
        if (window = doc&.default_view)
          rt.install_window(window)
          rt.install_browser_globals
          resources = ::Dommy::Rack::Resources.new(@session)
          # Off-thread network is opt-in: with a session executor, fetch / XHR
          # resolve through a DeferredResponse on this window's scheduler;
          # without one the handler stays synchronous.
          window.globals["__fetch_handler__"] = ::Dommy::Resources::FetchHandler.new(
            resources, executor: @session.network_executor, scheduler: window.scheduler
          )
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

      # Collect a JS error / console log into the cross-realm streams and fan it
      # out to any registered observers (the Trace).
      def record_js_error(err)
        @js_errors << err
        @js_error_listeners.each { |cb| cb.call(err) }
      end

      def record_console(log)
        @console << log
        @console_listeners.each { |cb| cb.call(log) }
      end
    end
  end
end
