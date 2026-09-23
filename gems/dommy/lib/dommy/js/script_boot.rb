# frozen_string_literal: true

module Dommy
  module Js
    # Boot a parsed document's `<script>` tags like a browser: run them in two
    # passes that mirror the HTML spec, set `document.currentScript` around each,
    # and replay the readyState lifecycle so ready-gated startup code (Stimulus /
    # Turbo / jQuery ready) takes the real path.
    #
    #   loading -> parser-blocking classic scripts (document order)
    #           -> deferred scripts: modules + classic `defer` (document order)
    #           -> interactive (DOMContentLoaded)
    #           -> complete (load)
    #
    # The two passes matter: a `<script type="module">` is *deferred* — it must
    # run after the parser-inserted classic scripts even when it appears earlier
    # in the document (e.g. a Nuxt entry module placed above the inline
    # `window.__NUXT__ = {...}` bootstrap it depends on). Running everything in
    # one document-order pass would execute the module against half-initialized
    # globals. A failed fetch or a throwing script is isolated so the rest of the
    # page still loads: a throwing script's exception is REPORTED at the window
    # (WHATWG "report an exception", so `window.onerror` sees it and the host
    # hears only what the page left unhandled), while `on_error` stays the
    # fallback for a windowless document. Shared by `Dommy::Browser` and the
    # Capybara driver so script boot lives in one place.
    #
    # The module is the stable entry point; the work lives on ScriptBooter, a
    # short-lived instance that holds the runtime / document / resources /
    # on_error collaborators so they aren't threaded through every step.
    module ScriptBoot
      module_function

      def run_document_scripts(runtime, document, resources: nil, on_error: nil, on_script: nil)
        ScriptBooter.new(runtime, document, resources: resources, on_error: on_error, on_script: on_script).run
      end

      # Re-run the inline-handler scan. Idempotent — the scan skips an element
      # whose handler is already compiled — so it can be replayed whenever an
      # element carrying an `on*` attribute turns up after boot (cloneNode,
      # innerHTML, a fragment inserted by a template). The scan itself lives in
      # host_runtime.js, next to the handler-attribute sets it reads and the
      # per-attribute compilation the runtime setAttribute path shares with it.
      def wire_inline_handlers(runtime, on_error: nil)
        runtime.execute("__rbHost.wireInlineHandlers();")
      rescue StandardError => e
        on_error&.call(e)
      end

      # Fetch + execute a single `<script src>` that was dynamically inserted into
      # an already-booted document (webpack/Vite on-demand chunk loading), then
      # fire its load / error event so the loader's promise settles.
      def run_external_script(runtime, document, element, src, resources: nil, on_error: nil)
        ScriptBooter.new(runtime, document, resources: resources, on_error: on_error).run_inserted_external(element, src)
      end
    end

    # One document's script-boot run. Instantiated per boot by ScriptBoot; the
    # collaborators are ivars so the per-script steps take only what varies.
    class ScriptBooter
      def initialize(runtime, document, resources: nil, on_error: nil, on_script: nil)
        @runtime = runtime
        @document = document
        @resources = resources
        @on_error = on_error
        @on_script = on_script
        @loader = nil
      end

      def run
        @runtime.set_document_ready_state("loading")
        @loader = install_module_loader
        wire_inline_event_handlers
        scripts = @document.scripts.to_a
        # Pass 1: parser-blocking classic scripts, in document order.
        scripts.each { |element| run_one(element) unless deferred?(element) }
        # Pass 2: deferred scripts (modules + classic `defer`), in document order.
        scripts.each { |element| run_one(element) if deferred?(element) }
        @runtime.set_document_ready_state("interactive")
        @runtime.set_document_ready_state("complete")
      end

      def wire_inline_event_handlers
        ScriptBoot.wire_inline_handlers(@runtime, on_error: @on_error)
      end

      # Fetch + run a dynamically-inserted external script, then fire the event a
      # loader awaiting the element is listening for. The src was already taken
      # from the element by the mutation coordinator, so this does not re-consume
      # pending state.
      #
      # `error` means the FETCH failed — that is the only thing the element's
      # event reports. A script that downloaded fine and then threw still fires
      # `load`, because the load succeeded; its exception is reported at the
      # global instead. Conflating the two tells a chunk loader (webpack, Vite)
      # that the network failed, so it retries or gives up on a chunk that is
      # sitting right there.
      def run_inserted_external(element, src)
        url = resolve_url(src) if @resources
        response = (@resources.get(url) if url)
        return dispatch_script_event(element, "error") unless response&.success?

        begin
          with_current_script(element) { @runtime.load_script_cached(response.body, cache_key: url) }
        rescue StandardError => e
          report_exception(e)
        end
        dispatch_script_event(element, "load")
      rescue StandardError => e
        # The fetch itself blew up (a resources adapter raising, not a page
        # exception): nothing loaded, so the element reports a failure.
        report_exception(e)
        dispatch_script_event(element, "error")
      end

      private

      # WHATWG "report an exception" for a script whose EVALUATION threw: the
      # exception belongs to the page, so it is reported at the global (firing
      # `window.onerror`, which a page's error reporting listens on) rather than
      # handed straight to the host. Only a report the page leaves unhandled
      # reaches the host, through the window's unhandled-error seam.
      #
      # `on_error` is the fallback for a document with no window to report to
      # (nothing else could hear it) and for the internal failures that are not
      # page exceptions at all.
      def report_exception(error)
        window = (@document.default_view if @document.respond_to?(:default_view))
        return @on_error&.call(error) unless window.respond_to?(:__internal_report_exception__)

        Dommy::Internal::ExceptionReport.report_at(window, error, value: page_value_for(error))
      end

      # What the page should see as `event.error`. An engine that raises a host
      # exception for a script\'s throw has already discarded the JS value, so
      # there is nothing left to hand over: the page would get an opaque husk
      # with no `message` or `stack`, and a handler reading either would itself
      # throw — taking its `preventDefault()` down with it. A runtime that can
      # rebuild an equivalent Error inside the realm gets to; nil falls back to
      # whatever was caught.
      def page_value_for(error)
        return nil unless @runtime.respond_to?(:rebuild_error)

        @runtime.rebuild_error(error)
      end

      # Fire the script's load/error event ASYNCHRONOUSLY (a microtask), like a
      # real browser. Code commonly does `head.appendChild(s); s.onload = …`
      # (handlers set AFTER insertion), so a synchronous dispatch — during the
      # appendChild — would fire before any handler is attached and be missed,
      # hanging a loader that awaits onload (e.g. note.com's gtag plugin, which
      # blocked Nuxt hydration). Deferring to a microtask lets the handler attach
      # first.
      def dispatch_script_event(element, type)
        return unless element.respond_to?(:dispatch_event)

        fire = proc { element.dispatch_event(Dommy::Event.new(type)) rescue nil }
        scheduler = (@document.default_view&.scheduler if @document.respond_to?(:default_view))
        scheduler ? scheduler.queue_microtask(fire) : fire.call
      end

      # Whether the element runs in the deferred pass rather than at its parse
      # position. Module scripts are always deferred; a classic script is
      # deferred only with a `src` and the `defer` attribute (inline classic
      # scripts ignore `defer`). `async` opts out of deferral — it runs as soon
      # as it is available, which in this synchronous model is the first pass.
      def deferred?(element)
        return false if element.async

        module_script?(element) || (external?(element) && element.defer)
      end

      def module_script?(element) = element.type.to_s.strip.downcase == "module"
      def external?(element) = !element.src.to_s.empty?

      # Wire the ESM resolver before any module runs: parse the page's first
      # <script type="importmap">, then resolve bare specifiers through it and
      # fetch module sources through `resources`. Returns the loader so inline
      # modules can be seeded under a document URL.
      def install_module_loader
        loader = ModuleLoader.new(@resources, parse_import_map, base_url: document_base)
        # The engine requires a Proc specifically.
        @runtime.module_loader = ->(specifier, importer) { loader.call(specifier, importer) }
        loader
      end

      def parse_import_map
        el = @document.scripts.find { |s| s.type.to_s.strip.downcase == "importmap" }
        ImportMap.parse(el ? el.text : "")
      end

      # Run one <script> element and, only when it actually had pending work,
      # notify `on_script` (element, error) — success with nil, failure with the
      # raised error (alongside the existing `on_error`). Skipped/non-classic
      # elements (no pending body/src/module) are not reported.
      def run_one(element)
        @on_script.call(element, nil) if run_pending(element) && @on_script
      rescue StandardError => e
        report_exception(e)
        @on_script&.call(element, e)
      end

      # Execute the element's pending inline body / external src / module, and
      # return whether any of them matched (so run_one knows a script ran).
      def run_pending(element)
        if (body = element.__internal_take_pending_script__)
          with_current_script(element) { @runtime.load_script(body) }
        elsif (src = element.__internal_take_pending_src__)
          run_external(element, src)
        elsif (mod = element.__internal_take_pending_module__)
          run_module(mod)
        else
          return false
        end
        true
      end

      # An ES module script. `currentScript` is null for modules (spec), so it
      # is not set. An inline body is seeded under the document URL (so its
      # relative imports resolve against the page) and pinned to the page's
      # `import.meta.url`: the engine derives import.meta.url from the module's
      # unique cache key, which carries a `#dommy-inline-N` fragment for a
      # second inline module, so we set `import.meta.url` (writable) to the
      # clean page URL up front. An external module loads by its own URL.
      def run_module(mod)
        kind, value = mod
        if kind == :inline
          base = inline_base
          # No newline, so the original body's line numbers are preserved.
          body = "import.meta.url = #{base.to_json}; #{value}"
          @runtime.load_module_url(@loader.seed_inline(base, body))
        elsif (url = resolve_url(value))
          @runtime.load_module_url(url)
        end
      end

      # The page URL an inline module is identified by (its import.meta.url and
      # the base for its relative imports).
      def inline_base
        base = document_base
        base.empty? ? "about:blank" : base
      end

      def run_external(element, src)
        return unless @resources

        url = resolve_url(src)
        return unless url

        response = @resources.get(url)
        return unless response&.success?

        # Cache the compiled bytecode by URL: vendored bundles re-parse on
        # every fresh VM otherwise.
        with_current_script(element) { @runtime.load_script_cached(response.body, cache_key: url) }
      end

      # Resolve a script's `src` against the document's base URL, which is the
      # realm's own location (correct for frames too).
      def resolve_url(src)
        ::URI.join(document_base, src).to_s
      rescue ::URI::InvalidURIError
        nil
      end

      # The document's effective base URL string: its `<base>`-derived base
      # URI, falling back to the realm's own location. Empty string when
      # neither is set (callers decide their own fallback).
      def document_base
        base = @document.base_uri
        base = @document.url if base.to_s.empty?
        base.to_s
      end

      def with_current_script(element)
        @document.__internal_set_current_script__(element)
        yield
      ensure
        @document.__internal_set_current_script__(nil)
      end
    end
  end
end
