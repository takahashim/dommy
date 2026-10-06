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

      # Activate the event handler content attributes the parser left on the
      # document's elements (it runs no attribute change steps). Safe to
      # replay: an attribute is activated once, and one whose handler was
      # since set by script is left alone. Compilation itself is lazy (the
      # handler's first read or event) and lives in host_runtime.js.
      def wire_inline_handlers(_runtime = nil, document: nil, on_error: nil)
        document&.__internal_activate_parsed_event_handlers__
      rescue StandardError => e
        on_error&.call(e)
      end

      # The module loader the document's boot installed, so a module script
      # inserted later resolves its imports through the same import map and
      # module map.
      MODULE_LOADERS = ObjectSpace::WeakKeyMap.new

      def register_module_loader(document, loader)
        MODULE_LOADERS[document] = loader
      end

      def module_loader_for(document) = MODULE_LOADERS[document]

      # Fetch + execute a single script that was dynamically inserted into an
      # already-booted document (webpack/Vite on-demand chunk loading, or a
      # `<script type=module>`), then fire its load / error event so the
      # loader's promise settles.
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
        # The modules the page fetched, for the next page of its origin to read
        # as bytecode.
        ModulePreload.register(@runtime, @loader.served)
        @runtime.set_document_ready_state("interactive")
        @runtime.set_document_ready_state("complete")
      end

      def wire_inline_event_handlers
        ScriptBoot.wire_inline_handlers(@runtime, document: @document, on_error: @on_error)
      end

      # Run a script that was not parser-inserted once its turn comes: an
      # external classic script (its fetch, then execution, then `load` — or
      # `error` when the fetch failed), or a module script, inline or external.
      # The element was already prepared by the post-connection steps, which
      # kept what to run on it; `src` is the URL they resolved.
      #
      # `error` means the FETCH failed — that is the only thing the element's
      # event reports. A script that downloaded fine and then threw still fires
      # `load`, because the load succeeded; its exception is reported at the
      # global instead. Conflating the two tells a chunk loader (webpack, Vite)
      # that the network failed, so it retries or gives up on a chunk that is
      # sitting right there.
      def run_inserted_external(element, src)
        prepared = element.__internal_prepared_script__ if element.respond_to?(:__internal_prepared_script__)
        if prepared&.type == :module
          @loader = ScriptBoot.module_loader_for(@document) || install_module_loader
          return run_module(element, prepared)
        end

        run_classic_external(element, src)
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
        window = reporting_window
        return @on_error&.call(error) unless window

        Dommy::Internal::ExceptionReport.report_at(window, error, value: page_value_for(error))
      end

      # The window an exception is reported at, or nil when there is none to
      # report to — a document parsed without a browsing context, or one whose
      # window predates the unhandled-error seam. Asked here rather than at each
      # use, so the shape of "this document might not have a window" is written
      # down once.
      def reporting_window
        window = (@document.default_view if @document.respond_to?(:default_view))
        window if window.respond_to?(:__internal_report_exception__)
      end

      # The scheduler a deferred step runs on, or nil to run it inline. Same
      # reason as reporting_window: one place knows how to reach it.
      def microtask_scheduler
        window = (@document.default_view if @document.respond_to?(:default_view))
        window&.scheduler if window.respond_to?(:scheduler)
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

      # Fire the script's `load` / `error` event — a trusted event, fired
      # synchronously as "execute the script element" does once the script ran
      # (or failed to load). A dynamically inserted script is already run from
      # a later microtask or task, so `head.appendChild(s); s.onload = …` has
      # attached its handler by now. A listener that throws is reported by the
      # dispatch itself; what the rescue covers is the dispatch failing outright.
      def fire_script_event(element, type)
        return nil unless element.respond_to?(:__internal_fire_event__)

        element.__internal_fire_event__(type)
        nil
      rescue StandardError => e
        @on_error&.call(e)
        nil
      end

      # Whether the element runs in the deferred pass rather than at its parse
      # position. Module scripts are always deferred; a classic script is
      # deferred only with a `src` and the `defer` attribute (inline classic
      # scripts ignore `defer`). `async` opts out of deferral — it runs as soon
      # as it is available, which in this synchronous model is the first pass.
      def deferred?(element)
        return false if element.async

        type = element.__internal_script_type__
        type == :module || (type == :classic && external?(element) && element.defer)
      end

      # "If el has a src attribute" — the CONTENT attribute, not the IDL one. The
      # IDL `src` is a URL reflection, so `src=""` reads back as the document's
      # own address rather than as the empty string, and an empty src is the one
      # case where the two answers differ.
      def external?(element) = !element.__internal_attribute_value__("src").nil?

      # Wire the ESM resolver before any module runs: parse the page's first
      # <script type="importmap">, then resolve bare specifiers through it and
      # fetch module sources through `resources`. Returns the loader so inline
      # modules can be seeded under a document URL.
      def install_module_loader
        loader = ModuleLoader.new(@resources, parse_import_map, base_url: document_base,
                                                                preloaded: ModulePreload.preloaded(@runtime))
        # The engine requires a Proc specifically.
        @runtime.module_loader = ->(specifier, importer) { loader.call(specifier, importer) }
        ScriptBoot.register_module_loader(@document, loader)
        loader
      end

      def parse_import_map
        el = @document.scripts.find { |s| s.__internal_script_type__ == :importmap }
        ImportMap.parse(el ? el.text : "")
      end

      # Prepare one parser-inserted <script> element and execute what it
      # prepared to, notifying `on_script` (element, error) when a classic or
      # module script ran — success with nil, failure with the raised error
      # (alongside the report at the window). A script that prepared to nothing
      # (empty, an unknown type, `nomodule`, already started) is not reported.
      def run_one(element)
        prepared = element.__internal_prepare_script__
        return unless prepared && %i[classic module].include?(prepared.type)

        error =
          if prepared.type == :module
            run_module(element, prepared)
          elsif prepared.external
            run_classic_external(element, prepared.url)
          else
            execute_classic(element) { @runtime.load_script(prepared.source) }
          end
        @on_script&.call(element, error)
      end

      # HTML "execute the script element" for a classic script: currentScript
      # is the element while it runs, and back to its old value afterwards; a
      # throw is reported at the window from inside that window (the report is
      # part of running the script), then a microtask checkpoint runs before
      # the next script, as "clean up after running script" does. Returns the
      # error, if any.
      def execute_classic(element)
        error = nil
        @document.__internal_with_current_script__(element) do
          yield
        rescue StandardError => e
          error = e
          report_exception(e)
          checkpoint
        end
        error
      end

      # A microtask checkpoint, for the paths where the engine did not run one
      # (a throwing script unwinds past its own).
      def checkpoint
        @runtime.drain_microtasks
      rescue StandardError => e
        @on_error&.call(e)
      end

      # Fetch an external classic script, run it, then fire `load` at the
      # element; a failed fetch fires `error` instead and runs nothing.
      def run_classic_external(element, url)
        body = fetch(url)
        return fire_script_event(element, "error") unless body

        # Cache the compiled bytecode by URL: vendored bundles re-parse on
        # every fresh VM otherwise.
        error = execute_classic(element) { @runtime.load_script_cached(body, cache_key: url) }
        fire_script_event(element, "load")
        error
      end

      # The body of a successful fetch of `url`, or nil. A resources adapter
      # that raises is a failed fetch too (reported to the host, not the page).
      def fetch(url)
        # A `data:` URL is fetched by its scheme, not over the network.
        if (decoded = Dommy::DataUri.parse(url))
          return decoded[:body]
        end
        return nil unless @resources && url

        response = @resources.get(url)
        response.body if response&.success?
      rescue StandardError => e
        @on_error&.call(e)
        nil
      end

      # An ES module script. `currentScript` is null for modules (spec), so it
      # is not set. An inline body is seeded under the document URL (so its
      # relative imports resolve against the page) and pinned to the page's
      # `import.meta.url`: the engine derives import.meta.url from the module's
      # unique cache key, which carries a `#dommy-inline-N` fragment for a
      # second inline module, so we set `import.meta.url` (writable) to the
      # clean page URL up front. An external module loads by its own URL, and
      # fires `load` after it ran — or `error`, running nothing, when its own
      # fetch failed. Returns the error the evaluation raised, if any.
      def run_module(element, prepared)
        if prepared.external
          url = prepared.url
          return fire_script_event(element, "error") unless @loader.prefetch(url)

          error = evaluate_module { @runtime.load_module_url(url) }
          fire_script_event(element, "load")
          error
        else
          base = inline_base
          # No newline, so the original body's line numbers are preserved.
          body = "import.meta.url = #{base.to_json}; #{prepared.source}"
          evaluate_module { @runtime.load_module_url(@loader.seed_inline(base, body)) }
        end
      end

      def evaluate_module
        yield
        nil
      rescue StandardError => e
        report_exception(e)
        checkpoint
        e
      end

      # The page URL an inline module is identified by (its import.meta.url and
      # the base for its relative imports).
      def inline_base
        base = document_base
        base.empty? ? "about:blank" : base
      end

      # The document's effective base URL string: its `<base>`-derived base
      # URI, falling back to the realm's own location. Empty string when
      # neither is set (callers decide their own fallback).
      def document_base
        base = @document.base_uri
        base = @document.url if base.to_s.empty?
        base.to_s
      end
    end
  end
end
