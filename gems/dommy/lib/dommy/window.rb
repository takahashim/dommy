# frozen_string_literal: true

require_relative "internal/window_constructors"
require_relative "internal/origin"

require "uri"

require_relative "internal/css/cascade"
require_relative "internal/css/media_query"

# Dommy — a happy-dom-style DOM polyfill in pure Ruby. Backbone is
# Nokogiri::HTML5 plus a small scheduler/event-loop layer.
#
# Two views into the same objects:
#   - Public Ruby API (snake_case methods like `text_content`,
#     `append_child`) for CRuby users writing tests against rendered
#     HTML.
#   - `__js_get__` / `__js_set__` / `__js_call__` / `__js_new__`
#     bridge protocol for JS bridge embedders — dispatches into the
#     same underlying Ruby methods.
module Dommy
  # The browser global. `JS.global` from inside wasm resolves to this.
  # Property access (`JS.global[:document]`, `JS.global[:console]`) is
  # routed through `#__js_get__`. Method calls (`JS.global.call(:foo)`)
  # are routed through `#__js_call__`.
  class Window
    include Internal::WindowConstructors

    include EventTarget
    extend Internal::EventHandlers::AnswersIdlAttributes

    # Window attributes declared [Replaceable]: an assignment from script
    # replaces the accessor with a plain data property, which later reads see.
    REPLACEABLE_ATTRIBUTES = %w[
      self frames parent opener external locationbar menubar personalbar scrollbars statusbar toolbar
      screen screenX screenLeft screenY screenTop innerWidth innerHeight outerWidth outerHeight
      scrollX pageXOffset scrollY pageYOffset devicePixelRatio origin visualViewport
    ].to_set.freeze

    attr_reader :document, :scheduler, :location, :globals, :custom_elements, :navigator, :history

    # Opt into best-effort geometry: when true, getBoundingClientRect / client* /
    # offset* return non-zero estimates from a cheap pseudo-layout (viewport width
    # + text content) instead of all-zero. Off by default so the no-layout
    # contract (and the tests asserting 0) is unchanged; a browser front end
    # (dommynx) turns it on so sites that bail on all-zero rects can proceed.
    attr_accessor :approximate_layout
    # The `<iframe>`/frame element hosting this window's browsing context (nil for
    # a top-level window). Lets rendering-dependent code (getComputedStyle) tell
    # whether this document is inside a non-rendered frame.
    attr_accessor :frame_element

    # `window.origin` — this environment's origin, serialized. The one place
    # that asks the Location object for it: Location keeps its components behind
    # the bridge ABI on purpose (see its own note), so a Ruby caller that wants
    # an origin asks the Window, not `location.__js_get__("origin")`.
    def origin
      return "" unless @location

      Internal::Origin.of_window(self)
    end

    # The child browsing contexts' windows, in document order — one per `<iframe>`
    # (nil for a frame whose content document isn't wired). Backs `window[i]` /
    # `window.frames[i]`.
    def frame_windows
      @document.query_selector_all("iframe").map do |frame|
        frame.respond_to?(:content_window) ? frame.content_window : nil
      end
    end

    # HTML §7.2.2.3 "Named access on the Window object". The Window supports
    # named properties ([Global], [LegacyUnenumerableNamedProperties]): its
    # child navigables' target names, the names of its document's embed / form /
    # img / object elements, and the ids of its document's elements, in tree
    # order. They sit behind every real member and JS global (no
    # [LegacyOverrideBuiltIns]) — the bridge asks for them last.
    WINDOW_NAMED_ELEMENTS = %w[embed form img object].freeze

    def __js_named_props__
      names = []
      first_named = Set.new
      window_named_candidates.each do |el|
        if (target = child_navigable_name(el))
          # The document-tree child navigable target name property set: the
          # first navigable of each non-empty name, kept when its document is
          # same origin with this window.
          if !target.empty? && first_named.add?(target) && same_origin_child?(el)
            names << target
          end
        end
        name = window_named_element_name(el)
        names << name if name
        id = el.__internal_attribute_value__("id").to_s
        names << id unless id.empty?
      end
      names.uniq
    end

    # The value of the named property `name`: the WindowProxy of the first
    # container whose child navigable is named `name`, else the one element
    # named or identified by it, else a live HTMLCollection of all of them.
    def __js_named_get__(name)
      name = name.to_s
      return Bridge::ABSENT if name.empty?

      candidates = window_named_candidates
      container = candidates.find { |el| child_navigable_name(el) == name }
      # (An iframe whose document the host has not supplied yet has no window
      # here; its name then falls through to the elements.)
      window = container&.content_window
      return window if window

      elements = window_named_elements(candidates, name)
      return Bridge::ABSENT if elements.empty?
      return elements.first if elements.size == 1

      HTMLCollection.new { window_named_elements(window_named_candidates, name) }
    end

    # Optional WebSocket transport factory (a host seam, like the document's
    # external_script_runner): `->(ws, url, protocols) -> transport | nil`.
    # A returned transport owns the connection — WebSocket#send / #close
    # delegate to it, and it reports lifecycle back through the
    # __internal_transport_*__ callbacks (on the page thread). nil falls back to the
    # in-memory stub (auto-open + __test_simulate_*__ seams).
    attr_accessor :websocket_connector

    # Optional EventSource (Server-Sent Events) transport factory (a host
    # seam, like websocket_connector): `->(es, url, with_credentials) ->
    # transport | nil`. A returned transport owns the stream — EventSource#close
    # delegates to it, and it reports lifecycle back through the
    # __internal_transport_*__ callbacks (on the page thread). nil falls back to the
    # in-memory stub (auto-open + __test_simulate_*__ seams).
    attr_accessor :event_source_connector

    # Navigation host seam (see Dommy::Navigation). Cross-document navigation
    # intents (link activation, location.assign/replace/reload, history
    # traversal across a document boundary) are routed to this delegate. The
    # default NullDelegate records attempts without navigating, so behaviour is
    # unchanged until an embedder installs a real delegate.
    attr_accessor :navigation_delegate

    # What a dialog handler returns to decline a dialog — it is not the one it
    # is waiting for — leaving the answer to the headless default below. A
    # handler cannot say that with nil or false: both are answers.
    DIALOG_UNANSWERED = :__dommy_dialog_unanswered__

    # Optional host seam for native JavaScript dialogs. It receives the dialog
    # type (`:alert`, `:confirm`, or `:prompt`), its message, and (for prompts)
    # the default value, and answers it — or returns DIALOG_UNANSWERED to pass.
    # A headless Window has no user to ask, so the fallback remains alert ->
    # nil, confirm -> false, prompt -> nil. Browser front ends can install a
    # handler to supply a deterministic answer.
    attr_accessor :dialog_handler

    def initialize(host = nil, backend_doc: nil)
      @host = host
      @navigation_delegate = Navigation::NullDelegate.new
      @scheduler = Scheduler.new
      # A timer / rAF callback that throws is reported at this global rather than
      # tearing down the clock (WHATWG "report an exception"; see Scheduler).
      @scheduler.exception_reporter = ->(error) { __internal_report_task_exception__(error) }
      @crypto = Crypto.new(self)
      @css_namespace = CSSNamespace.new
      @cookie_store = CookieStore.new(self)
      @location = Location.new(self)
      @history = History.new(self, @location)
      # `JS.global[:__some_key__] = ...` from user code lands here. Test code
      # uses this for stub installation (e.g. a custom `__fetch_stub__`);
      # production code stays on the typed accessors. Kept last in the read
      # fallback so it can't shadow intentional getters.
      @globals = {}
      @document = Document.new(host, backend_doc: backend_doc)
      @document.default_view = self
      # Per the HTML parsing algorithm, a <template>'s contents are parsed into a
      # separate "template contents" DocumentFragment, not as children of the
      # element. Backends (libxml2) leave them as direct children, so migrate
      # eagerly at page-load time — before any framework walks the tree. Without
      # this, a tree-walk (Alpine's x-for/x-if scan, etc.) descends into the
      # template's inert content and evaluates directives there out of scope.
      @document.migrate_template_descendants(@document.backend_doc)
      @document.__internal_run_parsed_insertion_steps__
      @custom_elements = CustomElementRegistry.new(self)
      @navigator = Navigator.new(self)
      # All JS global constructors (`new Event()`, `new URL()`, ...) live in a
      # single name→Constructor registry rather than one ivar + one __js_get__
      # arm each.
      @constructors = Bridge::ConstructorRegistry.new(build_constructors)
    end

    # Bridge protocol: respond to a JS-style property read by name.
    # Returns either a Ruby primitive (Integer / String / true / false /
    # nil), a Hash/Array (for JS object/array literals), or a Dom::*
    # instance for live DOM/BOM objects.
    #
    # Anything outside the surface we've explicitly polyfilled returns
    # nil (= JS undefined). Spec failures here are the signal to widen
    # the surface in a future session.
    def __js_get__(key)
      ctor = @constructors[key]
      return ctor if ctor

      # A [Replaceable] attribute the page assigned is a plain data property from
      # then on.
      return @globals[key] if REPLACEABLE_ATTRIBUTES.include?(key) && @globals.key?(key)

      case key
      when "event"
        # Legacy `window.event` (DOM "Legacy extensions to the Window
        # interface"): the event currently being dispatched, and *absent*
        # (undefined, not null) at any other time — or while a shadow tree's
        # listener runs — so feature detection like `window.event === undefined`
        # (React's getCurrentEventPriority) takes the not-supported path instead
        # of dereferencing null. The attribute is [Replaceable]: an assignment
        # replaces the accessor with a data property, so a value the page set
        # wins from then on, dispatch or not.
        @globals.key?("event") ? @globals["event"] : (@current_event || Bridge::UNDEFINED)
      when "document"
        @document
      when "length"
        # HTML `window.length`: the number of document-tree child navigables
        # (the frames `window[i]` indexes). [Replaceable], like `event`: once a
        # page assigns it, its own value wins.
        @globals.key?("length") ? @globals["length"] : frame_windows.size
      when "window", "self", "frames"
        # Always this window's own WindowProxy, browsing context or not.
        self
      when "parent"
        # The container's window for a nested browsing context, this window for
        # a top-level one — so `window === window.parent` and frame-walking loops
        # (testharness.js's `while (w != w.parent)`) terminate — and null once
        # the browsing context is gone.
        parent_window
      when "top"
        top_window
      when "frameElement"
        frame_element_for_script
      when "name"
        name
      when "opener"
        # No auxiliary browsing contexts are created, so there is never an opener.
        nil
      when "closed"
        closed?
      when "status"
        @status || ""
      when "locationbar", "menubar", "personalbar", "scrollbars", "statusbar", "toolbar"
        (@bar_props ||= {})[key] ||= BarProp.new(self)
      when "external"
        @external ||= External.new
      when "isSecureContext"
        secure_context?
      when "crossOriginIsolated"
        false
      when "originAgentCluster"
        # An agent cluster is origin-keyed only when the page asked for it with
        # the Origin-Agent-Cluster header, which Dommy never sees.
        false
      when "screenX", "screenLeft", "screenY", "screenTop"
        0
      when "crypto"
        @crypto
      when "cookieStore"
        @cookie_store
      when "console"
        :console
      when "Object"
        :object_ctor
      when "Array"
        :array_ctor
      when "JSON"
        :json_ctor
      when "performance"
        @performance ||= Performance.new(self)
      when "localStorage"
        local_storage
      when "sessionStorage"
        session_storage
      when "location"
        @location
      when "origin"
        origin
      when "history"
        @history
      when "CSS"
        @css_namespace
      when "fetch"
        FetchFn.new(self)
      when "customElements"
        @custom_elements
      when "navigator"
        @navigator
      when "screen"
        @screen ||= Screen.new(self)
      when "innerWidth", "outerWidth"
        media_environment.viewport_width
      when "innerHeight", "outerHeight"
        media_environment.viewport_height
      when "devicePixelRatio"
        media_environment.device_pixel_ratio
      when "scrollX", "pageXOffset"
        @scroll_x || 0
      when "scrollY", "pageYOffset"
        @scroll_y || 0
      when "scrollMaxX", "scrollMaxY"
        # No real content box to scroll past, so the max offset is 0.
        0
      when /\A\d+\z/
        # `window[i]` / `window.frames[i]` — the i-th child browsing context's
        # window (the i-th `<iframe>`'s contentWindow), or ABSENT past the end.
        frame = frame_windows[key.to_i]
        frame.nil? ? Bridge::ABSENT : frame
      when ->(k) { Internal::EventHandlers.idl_attribute?(self, k) }
        # An event handler IDL attribute (GlobalEventHandlers +
        # WindowEventHandlers): the registered handler, or null (not undefined)
        # when unset — matching the spec and Element's on* getter. Only the
        # names the IDL declares: `window.onboarding = {...}` stays a global.
        on_handler(event_name_from_on(key))
      else
        # A stashed global wins (even if its value is nil/null); a key never set
        # is genuinely absent → ABSENT so JS sees `undefined` and `"x" in window`
        # is false (feature detection like `isUndefined(window.Vue)` works).
        @globals.key?(key) ? @globals[key] : Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      # `window.location = url` forwards to the Location object (WebIDL
      # [PutForwards=href]): equivalent to `location.href = url`, i.e. navigate.
      if key == "location" && @location
        @location.__js_set__("href", value.to_s)
        return nil
      end
      case key
      when "name"
        # The navigable's target name; a window without one ignores the write.
        @name = value.to_s if navigable?
        return nil
      when "status"
        @status = value.to_s
        return nil
      when "opener"
        # [Replaceable]-like: null clears the (always absent) opener; anything
        # else replaces the attribute with a data property.
        value.nil? ? @globals.delete("opener") : @globals["opener"] = value
        return nil
      end
      # `window.onload = fn` (and the other window event handlers) registers a
      # listener rather than stashing an expando, so the handler actually fires.
      if Internal::EventHandlers.idl_attribute?(self, key)
        set_on_handler(event_name_from_on(key), value)
        return nil
      end
      # Stash arbitrary keys for later reads (e.g.
      # `JS.global[:__fetchy_stub__] = map`).
      @globals[key] = value
      # The Fetchy spec's `install_fetch_stub` resets `__fetch_count__`
      # to 0 inside its JS installer (`globalThis.__fetch_count__ = 0;
      # globalThis.fetch = ...`). Our polyfill ignores raw JS, so we
      # piggy-back on the stub assignment to perform the same reset
      # — without it the count accumulates across tests in one VM run.
      @globals["__fetch_count__"] = 0 if %w[__fetchy_stub__ __resource_fetch_stub__ __inject_fetch_stub__].include?(key)
      nil
    end

    include Bridge::Methods
    js_methods %w[
      fetch encodeURIComponent decodeURIComponent btoa atob addEventListener removeEventListener
      dispatchEvent setTimeout clearTimeout setInterval clearInterval requestAnimationFrame
      cancelAnimationFrame queueMicrotask requestIdleCallback cancelIdleCallback structuredClone
      matchMedia getComputedStyle scroll scrollTo scrollBy resizeTo resizeBy moveTo moveBy
      alert confirm prompt open reportError getSelection postMessage
      print close stop focus blur captureEvents releaseEvents
    ]
    def __js_call__(method, args)
      case method
      when "fetch"
        FetchFn.new(self).__js_call__("call", args)
      when "encodeURIComponent"
        Internal::GlobalFunctions.encode_uri_component(args[0])
      when "decodeURIComponent"
        Internal::GlobalFunctions.decode_uri_component(args[0])
      when "btoa"
        Internal::GlobalFunctions.btoa(args[0])
      when "atob"
        Internal::GlobalFunctions.atob(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "setTimeout"
        @scheduler.set_timeout(timer_handler(args[0]), timer_delay(args[1]), args.drop(2), this: self)
      when "clearTimeout"
        @scheduler.clear_timeout(args[0])
      when "setInterval"
        @scheduler.set_interval(timer_handler(args[0]), timer_delay(args[1]), args.drop(2), this: self)
      when "clearInterval"
        @scheduler.clear_interval(args[0])
      when "requestAnimationFrame"
        @scheduler.request_animation_frame(args[0])
      when "cancelAnimationFrame"
        @scheduler.cancel_animation_frame(args[0])
      when "queueMicrotask"
        @scheduler.queue_microtask(args[0])
      when "requestIdleCallback"
        @scheduler.request_idle_callback(args[0], (args[1].is_a?(Hash) && args[1]["timeout"]) || 0)
      when "cancelIdleCallback"
        @scheduler.cancel_idle_callback(args[0])
      when "structuredClone"
        Dommy.structured_clone(args[0])
      when "matchMedia"
        MediaQueryList.new(self, args[0].to_s)
      when "getComputedStyle"
        get_computed_style(args[0], args[1])
      when "resizeTo"
        resize_to(args[0], args[1])
      when "resizeBy", "moveTo", "moveBy", "captureEvents", "releaseEvents", "blur"
        # A headless window has no position or size the page may change, and
        # captureEvents / releaseEvents / blur do nothing by definition.
        nil
      when "print"
        print
      when "close"
        close
      when "stop"
        stop
      when "focus"
        focus
      when "scroll", "scrollTo"
        scroll_to(*args)
      when "scrollBy"
        scroll_by(*args)
      when "alert"
        handle_dialog(:alert, args[0].to_s, nil)
      when "confirm"
        handle_dialog(:confirm, args[0].to_s, nil)
      when "prompt"
        handle_dialog(:prompt, args[0].to_s, args[1].nil? ? "" : args[1].to_s)
      when "open"
        window_open(args[0], args[1], args[2])
      when "reportError"
        # WHATWG `self.reportError(e)` IS "report an exception" exposed to
        # authors: it fires the same `error` event an uncaught throw would, so a
        # library that funnels its own caught errors through it reaches
        # window.onerror (and, unhandled, the console) like a real one.
        # Through the same shaping every other report uses, so the page sees the
        # position the error carries (its JS frames, minus Dommy's own) rather
        # than line 0 of nowhere.
        Internal::ExceptionReport.report_at(self, Internal::ExceptionReport.thrown_host_error(args[0]))
        nil
      when "getSelection"
        document&.get_selection
      when "postMessage"
        post_message(args[0], args.length > 1 ? args[1] : "*", source: args[2])
      else
        # Additional window-level methods (fetch, location, history,
        # Promise, MutationObserver, etc.) arrive in later sessions.
        nil
      end
    end

    def __internal_event_parent__
      nil
    end

    # Backing store for the legacy `window.event` global, set and restored by
    # dispatch around each listener.
    def __internal_current_event__
      @current_event
    end

    def __internal_set_current_event__(event)
      @current_event = event
      nil
    end

    # WHATWG "report an exception": fire a cancelable `error` event carrying the
    # thrown value (`event.error`) and its message at this window, so
    # window.onerror / an "error" listener observes it. This is the ONE funnel
    # every uncaught exception goes through — a listener that threw during
    # dispatch, a `<script>` whose evaluation threw, a timer / rAF callback,
    # `reportError`. Returns whether the page HANDLED it (canceled the event,
    # via `preventDefault()` or an `onerror` returning true).
    #
    # An unhandled report is then announced to the host through
    # `__internal_on_unhandled_error__`. That is the browser's "may report the
    # error to a developer console" step: the console — and, for a test front
    # end, the error log that fails the test — sees only what the page did not
    # handle. A page with its own error reporting (Sentry, a deliberate
    # `window.onerror`) therefore suppresses it exactly as in a browser.
    #
    # `host_error` carries the original Ruby exception (with its backtrace) when
    # the caller has one, since `error_value` is the JS value the page sees and
    # is not necessarily diagnosable on the Ruby side.
    #
    # Re-entrancy is guarded so an "error" handler that itself throws doesn't
    # recurse into another report: its own throw is dropped and reported as
    # handled, so the guarded-out call does not reach the host either. Only the
    # call that raised the guard lowers it — a guarded-out call returns before
    # the ensure, or every throwing error listener after the first would find
    # the guard down and start a report of its own.
    def __internal_report_exception__(error_value, message, filename: "", lineno: 0, colno: 0, host_error: nil)
      return true if @reporting_exception

      @reporting_exception = true
      handled =
        begin
          !__internal_fire_event__("error", {"message" => message, "error" => error_value, "filename" => filename,
                                             "lineno" => lineno, "colno" => colno, "cancelable" => true},
            event_class: ErrorEvent)
        ensure
          @reporting_exception = false
        end
      __internal_notify_unhandled_error__(Internal::ExceptionReport.host_form(error_value, host_error)) unless handled
      handled
    end

    # WHATWG "notify about rejected promises": fire a cancelable
    # `unhandledrejection` at this window for a promise that rejected with no
    # handler. An unhandled one reaches the host through the same seam as an
    # uncaught exception.
    #
    # Returns whatever the host made of the report (its ledger entry, say), or
    # nil when the page handled it. That token is what a later `rejectionhandled`
    # hands back so the host can take the report away again.
    #
    # WHEN this runs is the engine's call, not ours: the spec decides at the end
    # of a microtask checkpoint, over the promises still unhandled then, so a
    # `.catch` attached later in the same checkpoint keeps the page silent. An
    # engine that instead notifies the moment a promise rejects reports handled
    # code too.
    def __internal_report_rejection__(reason_value, host_error: nil, promise: nil)
      return nil unless __internal_fire_event__("unhandledrejection",
        {"promise" => promise, "reason" => reason_value, "cancelable" => true}, event_class: PromiseRejectionEvent)

      __internal_notify_unhandled_error__(Internal::ExceptionReport.host_form(reason_value, host_error))
    end

    # The engine's promise-rejection hook, carrying the REAL promise and reason
    # (see the JS side's onPromiseRejection). Both halves of HTML's promise
    # rejection tracking arrive here.
    #
    # A reported promise is remembered against what the host made of the report,
    # so `rejectionhandled` can hand that token back and have the report
    # retracted. The map is keyed by the value's bridge ref, which is stable per
    # JS object, and lives on the window because both the realm and the reports
    # belong to this document.
    def __internal_handle_promise_rejection__(type, reason_value, promise: nil)
      @rejection_records ||= {}
      key = promise.respond_to?(:ref) ? promise.ref : promise
      if type == "rejectionhandled"
        __internal_report_rejection_handled__(reason_value, promise: promise, record: @rejection_records.delete(key))
      else
        record = __internal_report_rejection__(reason_value, promise: promise,
          host_error: Internal::ExceptionReport.thrown_host_error(reason_value))
        @rejection_records[key] = record unless record.nil?
      end
      nil
    end

    # WHATWG: a promise that was reported as unhandled has since been handled, so
    # fire `rejectionhandled` and tell the host to take the report back. The
    # event is NOT cancelable — the page is being informed, not consulted.
    def __internal_report_rejection_handled__(reason_value, promise: nil, record: nil)
      __internal_fire_event__("rejectionhandled", {"promise" => promise, "reason" => reason_value},
        event_class: PromiseRejectionEvent)
      __internal_notify_rejection_handled__(record) unless record.nil?
      nil
    end

    # Report a timer / rAF callback's exception (the Scheduler's seam). Split out
    # so the scheduler hands over the raw error and the shaping stays here.
    def __internal_report_task_exception__(error)
      Internal::ExceptionReport.report_at(self, error)
    end

    # Subscribe to exceptions and rejections the PAGE did not handle (the
    # console / test-error-log seam; see `__internal_report_exception__`). A
    # window is per-document, so a host re-subscribes after each navigation.
    def __internal_on_unhandled_error__(&block)
      (@unhandled_error_listeners ||= []) << block
      self
    end

    # Returns the last listener's value, which is the host's record of the
    # report (see `__internal_report_rejection__`). nil with no listeners.
    def __internal_notify_unhandled_error__(error)
      @unhandled_error_listeners&.map { |listener| listener.call(error) }&.last
    end

    # Subscribe to reports the page has since handled, to take them back. The
    # block receives the token the unhandled-error seam returned for that report.
    def __internal_on_rejection_handled__(&block)
      (@rejection_handled_listeners ||= []) << block
      self
    end

    def __internal_notify_rejection_handled__(record)
      @rejection_handled_listeners&.each { |listener| listener.call(record) }
      nil
    end

    # Fire `popstate` at this window: a trusted PopStateEvent carrying the
    # history state (`event.state`, which routers like Turbo branch on). History
    # calls it when a traversal or a fragment navigation changes the active
    # entry.
    def __internal_fire_popstate__(state)
      event = PopStateEvent.new("popstate", "state" => state, "hasUAVisualTransition" => false)
      dispatch_event(event.__internal_mark_trusted__)
    end

    # Fire `hashchange` at this window: a trusted HashChangeEvent with the full
    # URLs before and after the fragment changed.
    def __internal_fire_hashchange__(old_url, new_url)
      event = HashChangeEvent.new("hashchange", "oldURL" => old_url.to_s, "newURL" => new_url.to_s)
      dispatch_event(event.__internal_mark_trusted__)
    end

    alias fire_popstate __internal_fire_popstate__
    alias fire_hashchange __internal_fire_hashchange__

    # Whether this window's document is completely loaded: the `load` event has
    # been fired and handled. Until then a script-initiated Location navigation
    # replaces the current history entry rather than adding one.
    def __internal_completely_loaded__?
      @document.respond_to?(:__internal_completely_loaded__?) ? @document.__internal_completely_loaded__? : true
    end

    # Whether this window's document is the initial about:blank of its browsing
    # context (the blank document a new iframe starts with). Navigations away
    # from it, and pushState on it, replace the entry.
    attr_writer :__internal_initial_about_blank__

    def __internal_initial_about_blank__? = @__internal_initial_about_blank__ == true

    # Whether this window still has a navigable: a nested one loses it when the
    # frame that held its document leaves the tree (the Window survives — a
    # script may still hold it). A top-level Window always has one.
    def navigable?
      return false if @discarded

      frame = @frame_element
      frame.nil? || frame.is_connected?
    end

    # The embedder replaced this window's document with another (a
    # cross-document navigation): the window keeps existing for scripts that
    # hold it, but its document is no longer fully active.
    def __internal_discard__
      @discarded = true
      nil
    end

    # Whether this window's document is fully active: it has a navigable, and so
    # does every ancestor up to the top.
    def __internal_fully_active__?
      seen = []
      window = self
      while window && !seen.include?(window)
        return false unless window.navigable?

        seen << window
        frame = window.frame_element
        return true if frame.nil?

        window = frame.owner_document&.default_view
        return false if window.nil?
      end
      true
    end

    # `window.parent`: the parent navigable's window, or this window when it is
    # top-level; null without a navigable.
    def parent_window
      return nil unless navigable?

      @frame_element ? (@frame_element.owner_document&.default_view || self) : self
    end

    # `window.top`: the top-level traversable's window; null without a navigable
    # anywhere up the chain.
    def top_window
      return nil unless __internal_fully_active__?

      window = self
      seen = []
      while window.frame_element && !seen.include?(window)
        seen << window
        window = window.parent_window
      end
      window
    end

    # `window.frameElement`: the container element (`<iframe>`) of a nested
    # browsing context; null for a top-level one and once detached.
    def frame_element_for_script
      return nil unless @frame_element && navigable?

      @frame_element
    end

    # `window.name`: the navigable's target name. A nested one starts out as its
    # container's `name` attribute; a write replaces it.
    def name
      return "" unless navigable?

      @name || ""
    end

    # Name a nested navigable as its container's `name` attribute says when the
    # navigable is created (a later attribute change does not rename it).
    def __internal_seed_name__(value)
      @name ||= value.to_s unless value.nil?
      nil
    end

    # `window.closed`: no navigable, or close() has begun closing it.
    def closed?
      !navigable? || @closing == true
    end

    # `window.close()`: only a top-level, script-closable navigable closes — one
    # whose session history holds a single entry (Dommy creates no auxiliary
    # browsing contexts) — and only from a task. The request is recorded
    # (`__test_close_calls__`) and the embedder's navigation delegate, when it
    # answers `close_window`, is asked to close it.
    def close
      return nil unless navigable? && @frame_element.nil?
      return nil if @closing

      (@close_calls ||= []) << {closable: script_closable?}
      return nil unless script_closable?

      @closing = true
      @scheduler.set_timeout(proc { @navigation_delegate.close_window if @navigation_delegate.respond_to?(:close_window) }, 0)
      nil
    end

    def script_closable?
      @history.length == 1
    end

    # Each close() call that reached the closing steps, with whether the window
    # was script-closable (and so began closing).
    def __test_close_calls__ = (@close_calls || []).dup

    # `window.print()`: run the printing steps — fire `beforeprint` at this
    # window (and its child frames' windows), record the request
    # (`__test_print_calls__`), then fire `afterprint`. Called before the
    # document is ready for post-load tasks it waits for the load to complete.
    def print
      return nil unless __internal_fully_active__?

      if __internal_completely_loaded__?
        run_printing_steps
      else
        @print_when_loaded = true
      end
      nil
    end

    def __test_print_calls__ = @print_calls || 0

    # The end of loading: a print() made while the document loaded runs now.
    def __internal_ready_for_post_load_tasks__
      return unless @print_when_loaded

      @print_when_loaded = false
      run_printing_steps
    end

    # `window.stop()`: stop loading this window's navigable — the embedder's
    # navigation delegate drops a navigation it has not performed yet.
    def stop
      return nil unless navigable?

      @stop_calls = (@stop_calls || 0) + 1
      @navigation_delegate.stop if @navigation_delegate.respond_to?(:stop)
      nil
    end

    def __test_stop_calls__ = @stop_calls || 0

    # `window.focus()`: a browsing context with no system focus to take; it only
    # has to exist for the call to be allowed.
    def focus
      nil
    end

    # `isSecureContext`: whether the top-level creation URL is potentially
    # trustworthy (https:, file:, localhost, about:blank, ...).
    def secure_context?
      top = top_window || self
      Internal::Origin.potentially_trustworthy_url?(top.location.href)
    end

    # `window.open(url, target, features)`. The URL is parsed first (a failure
    # is a SyntaxError). A target naming this window (`_self`, the empty-ish
    # default aside), its parent (`_parent`), the top (`_top`) or an existing
    # frame by name navigates that navigable and returns its window. A new
    # browsing context (`_blank`, an unknown name) is not created headlessly: the
    # attempt is recorded (`__test_open_calls__`) and handed to the navigation
    # delegate's `open_window` when it has one, whose answer (a Window or nil —
    # a blocked popup) is returned.
    def window_open(url_arg, target_arg, features_arg)
      url = blank_arg?(url_arg) ? "" : url_arg.to_s
      target = blank_arg?(target_arg) ? "_blank" : target_arg.to_s
      target = "_blank" if target.empty?
      features = blank_arg?(features_arg) ? "" : features_arg.to_s
      resolved = nil
      unless url.empty?
        resolved = __internal_parse_url__(url)
        raise DOMException::SyntaxError, "Unable to open a window with invalid URL #{url.inspect}" if resolved.nil?
      end
      noopener = features.split(/[\s,]+/).any? { |f| %w[noopener noreferrer].include?(f.downcase.split("=").first) }

      existing = choose_navigable(target)
      if existing
        existing.location.__internal_navigate_to__(resolved, source: :window_open, sync_cross_doc: false) if resolved
        return noopener ? nil : existing
      end

      (@open_calls ||= []) << {url: resolved || "about:blank", target: target, features: features}
      opened = nil
      if @navigation_delegate.respond_to?(:open_window)
        opened = @navigation_delegate.open_window(url: resolved || "about:blank", target: target, features: features)
      end
      noopener ? nil : opened
    end

    def __test_open_calls__ = (@open_calls || []).dup

    # The rules for choosing a navigable, for the targets that name an existing
    # one: nil means a new one would be created.
    def choose_navigable(target)
      case target.downcase
      when "_self" then self
      when "_parent" then parent_window || self
      when "_top" then top_window || self
      when "_blank" then nil
      else find_named_window(target)
      end
    end

    # A window whose target name is `name`: this one, a descendant frame's, or
    # (walking up) an ancestor's or one of their descendants'.
    def find_named_window(name)
      return self if self.name == name

      seen = []
      window = self
      while window && !seen.include?(window)
        seen << window
        found = window.__internal_find_descendant_window__(name)
        return found if found
        return window if window.name == name

        window = window.frame_element ? window.parent_window : nil
      end
      nil
    end

    def __internal_find_descendant_window__(name)
      frame_windows.each do |child|
        next unless child
        return child if child.name == name

        found = child.__internal_find_descendant_window__(name)
        return found if found
      end
      nil
    end

    # --- Web Storage ---

    # Where this window's storage areas come from (see Dommy::StorageProvider).
    # An embedder installs one provider for every window of a browsing session —
    # pages it navigates between, and their frames — so localStorage is shared
    # per origin and sessionStorage per top-level session and origin. A nested
    # window without its own uses its container's; a lone window gets a private
    # one (nothing shared with any other window).
    def storage_provider=(provider)
      @storage_provider = provider
      provider&.register(self)
    end

    def storage_provider
      return @storage_provider if @storage_provider

      container = @frame_element&.owner_document&.default_view
      provider = container && !container.equal?(self) ? container.storage_provider : StorageProvider.new
      self.storage_provider = provider
      provider
    end

    # `window.localStorage` / `sessionStorage` — the Storage object for this
    # document's origin in the provider's area; an opaque origin has none.
    def local_storage
      @local_storage ||= Storage.new(self, storage_provider.local_area(storage_origin!), "localStorage")
    end

    def session_storage
      @session_storage ||= Storage.new(self, storage_provider.session_area(storage_origin!), "sessionStorage")
    end

    def storage_origin!
      origin = self.origin
      raise DOMException::SecurityError, "Storage is disabled for an opaque origin" if origin == "null" || origin.empty?

      origin
    end

    # Single firing point for cross-document navigation intents. Link
    # activation, location.assign/replace/reload and cross-boundary history
    # traversal all route here; the attached delegate (NullDelegate by default)
    # decides what happens. Same-document navigation never reaches this — it is
    # handled directly by Location/History (hashchange / popstate).
    def __internal_navigate__(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, target: nil, headers: {}, replace: false)
      @navigation_delegate&.navigate(
        url: url, method: method, body: body, params: params, enctype: enctype,
        target: target, headers: headers, replace: replace, source: source
      )
    end

    # --- Viewport / media environment (cssom-view) ---

    # The media-feature environment matchMedia and @media evaluate against
    # (viewport 1280x720, light scheme, dpr 1 by default). Mutable; after a
    # direct mutation call __internal_media_environment_changed__ to propagate —
    # resize_to does both for the viewport.
    def media_environment
      @media_environment ||= Internal::CSS::MediaQuery::Environment.default
    end

    def inner_width = media_environment.viewport_width
    def inner_height = media_environment.viewport_height

    # Resolve a (possibly relative) URL against the document base URL — the
    # API base URL of this window's environment, as fetch/XHR use when
    # constructing a request. Returns the input unchanged if it can't resolve.
    def __internal_resolve_url__(url)
      __internal_parse_url__(url) || url.to_s
    end

    # `url` parsed against the document base URL and serialized, or nil when
    # the URL parser fails on it.
    def __internal_parse_url__(url)
      base = @document&.base_uri.to_s
      Internal::UrlParser.serialize(Internal::UrlParser.parse(url.to_s, base.empty? ? nil : base))
    rescue Internal::UrlParser::Failure
      nil
    end

    # The path (with query) of a URL — lets a stub keyed by a path ("/api")
    # match its resolved absolute form ("http://host/api").
    def __internal_url_path__(url)
      uri = URI.parse(url.to_s)
      uri.query ? "#{uri.path}?#{uri.query}" : uri.path
    rescue URI::Error
      url.to_s
    end

    # Resize the virtual viewport: updates the environment, invalidates
    # computed styles (@media), re-evaluates handed-out MediaQueryLists
    # (firing their `change` events), and fires the window `resize` event.
    def resize_to(width, height)
      media_environment.viewport_width = width.to_i
      media_environment.viewport_height = height.to_i
      __internal_media_environment_changed__
      dispatch_event(Event.new("resize"))
      nil
    end

    def __internal_media_environment_changed__
      @document&.__internal_bump_style_generation__
      (@media_query_lists || []).each(&:__internal_environment_changed__)
      nil
    end

    def __internal_register_media_query_list__(mql)
      (@media_query_lists ||= []) << mql
      nil
    end

    # CSSOM getComputedStyle. With the makiri-backed CSS parser available
    # this resolves the full cascade (UA sheet + <style> sheets + style
    # attribute); without it, falls back to the element's inline style (the
    # historical behavior). A pseudo-element argument yields an empty
    # declaration (Dommy renders no ::before/::after boxes).
    def get_computed_style(element, pseudo_element = nil)
      return nil unless element

      if Internal::CSS::Parser.available?
        pseudo = pseudo_element.to_s
        Internal::CSS::ComputedStyleDeclaration.new(
          element, pseudo_element: pseudo.empty? ? nil : pseudo
        )
      else
        element.respond_to?(:style) ? element.style : nil
      end
    end

    private

    def window_named_candidates
      @document.respond_to?(:__internal_window_named_candidates__) ? @document.__internal_window_named_candidates__ : []
    end

    # The target name of a document-tree child navigable's container (an
    # iframe in the document tree), or nil for any other element.
    def child_navigable_name(el)
      el.is_a?(HTMLIFrameElement) ? el.__internal_navigable_target_name__ : nil
    end

    # Whether the container's child navigable's document is same origin with
    # this window. One not created yet is the initial about:blank document,
    # which is.
    def same_origin_child?(container)
      child = container.__internal_built_content_window__
      return true unless child

      own = origin
      !own.empty? && own != "null" && child.origin == own
    end

    # The name an embed / form / img / object element contributes, or nil.
    def window_named_element_name(el)
      return nil unless el.is_a?(HTMLElement) && WINDOW_NAMED_ELEMENTS.include?(el.local_name)

      name = el.__internal_attribute_value__("name").to_s
      name.empty? ? nil : name
    end

    # The named objects of this window with the name `name` that are elements.
    def window_named_elements(candidates, name)
      candidates.select { |el| window_named_element_name(el) == name || el.__internal_attribute_value__("id").to_s == name }
    end

    # The printing steps: beforeprint at this window and its child frames'
    # windows, the (recorded) print, afterprint likewise.
    def run_printing_steps
      fire_print_event("beforeprint")
      @print_calls = (@print_calls || 0) + 1
      fire_print_event("afterprint")
    end

    def fire_print_event(type)
      ([self] + frame_windows.compact).each do |window|
        window.dispatch_event(Event.new(type).__internal_mark_trusted__)
      end
    end

    def blank_arg?(value)
      value.nil? || value.equal?(Bridge::UNDEFINED)
    end

    # The native-dialog seam behind alert / confirm / prompt: ask the installed
    # `dialog_handler`, and fall back to the headless defaults (alert -> nil,
    # confirm -> false as "Cancel", prompt -> nil as "no input") when there is
    # none or it declines. The defaults live here alone, so a handler never has
    # to know them to pass a dialog it does not want.
    def handle_dialog(type, message, default_value)
      if @dialog_handler
        answer = @dialog_handler.call(type, message, default_value)
        return answer unless answer == DIALOG_UNANSWERED
      end

      type == :confirm ? false : nil
    end

    # Virtual scroll position. There's no real layout, but tracking a logical
    # `(scrollX, scrollY)` makes scroll-dependent behaviour observable: scrollTo/
    # scroll set it absolutely, scrollBy relatively, and a `scroll` event fires on
    # change so observers (e.g. Turbo's ScrollObserver, which records the position
    # into history restoration data and replays it on back/forward) work.
    def scroll_to(*args)
      x, y = parse_scroll_args(args, @scroll_x || 0, @scroll_y || 0, relative: false)
      update_scroll(x, y)
      PromiseValue.resolve(self, nil)
    end

    def scroll_by(*args)
      x, y = parse_scroll_args(args, @scroll_x || 0, @scroll_y || 0, relative: true)
      update_scroll(x, y)
      PromiseValue.resolve(self, nil)
    end

    # `window.postMessage` — the window post message steps: `message` is
    # serialized now (a JS caller's arrives already serialized by the realm,
    # transfer list and all), then a task on the posted message task source
    # (not a microtask: a later event-loop turn) delivers it, provided this
    # window's origin is `target_origin`. `target_origin` is "*" (anyone), "/"
    # (the source's own origin) or a serialized origin; `source` is the window
    # that posted, whose origin the event reports. A record this window cannot
    # deserialize fires `messageerror` instead.
    def post_message(message, target_origin = "*", source: nil)
      serialized = Dommy.structured_serialize(message)
      source ||= self
      source_origin = source.respond_to?(:origin) ? source.origin.to_s : origin.to_s
      target_origin = target_origin.to_s
      @scheduler.set_timeout(proc { deliver_posted_message(serialized, target_origin, source, source_origin) }, 0)
      nil
    end

    def deliver_posted_message(serialized, target_origin, source, source_origin)
      return unless target_origin == "*" || posted_origin_matches?(target_origin, source, source_origin)

      init = {"origin" => source_origin, "source" => source}
      begin
        data, ports = serialized.deserialize_with_transfer
      rescue DOMException::DataCloneError
        dispatch_event(MessageEvent.new("messageerror", init).__internal_mark_trusted__)
        return
      ensure
        serialized.release if serialized.respond_to?(:release)
      end
      dispatch_event(MessageEvent.new("message", init.merge("data" => data, "ports" => ports)).__internal_mark_trusted__)
    end

    # "targetWindow's associated Document is same origin with targetOrigin":
    # "/" stands for the source's own origin. An opaque origin is only ever
    # same origin with itself — the window posting to itself.
    def posted_origin_matches?(target_origin, source, source_origin)
      if target_origin == "/"
        return true if source.equal?(self)

        target_origin = source_origin
      end
      own = origin.to_s
      own != "null" && !own.empty? && own == target_origin
    end

    # Accept either positional `(x, y)` or a `{ left:, top: }` options dict.
    def parse_scroll_args(args, cur_x, cur_y, relative:)
      if args[0].is_a?(Hash)
        dx = scroll_coord(args[0]["left"] || args[0][:left])
        dy = scroll_coord(args[0]["top"] || args[0][:top])
      else
        dx = scroll_coord(args[0])
        dy = scroll_coord(args[1])
      end
      if relative
        [cur_x + (dx || 0), cur_y + (dy || 0)]
      else
        [dx.nil? ? cur_x : dx, dy.nil? ? cur_y : dy]
      end
    end

    def scroll_coord(value)
      return nil if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))

      value.is_a?(Numeric) ? value.to_i : value.to_s.to_i
    end

    def update_scroll(x, y)
      return nil if x == (@scroll_x || 0) && y == (@scroll_y || 0)

      @scroll_x = x
      @scroll_y = y
      dispatch_event(Event.new("scroll"))
      nil
    end

    # The timer delay (WebIDL `long`, default 0). A missing/undefined argument
    # or any non-numeric value coerces to 0 rather than raising.
    # The timeout argument, a WebIDL `long` (ToNumber, then ToInt32: NaN and
    # the infinities are 0, everything else truncates and wraps modulo 2^32,
    # so 2**32 + 1 is 1). The timer steps clamp a negative one to 0.
    def timer_delay(value)
      value = 0 if value.nil? || value.equal?(Bridge::UNDEFINED)
      Internal::WebIDL.long(value)
    end

    # A timer's handler: a function is invoked as it is; anything else is
    # converted to a string and, when the timer fires, compiled and run as a
    # classic script in the window's global scope.
    def timer_handler(handler)
      return handler if CallableInvoker.js_callable?(handler) || handler.respond_to?(:call)

      source = handler.nil? || handler.equal?(Bridge::UNDEFINED) ? (handler.nil? ? "null" : "undefined") : handler.to_s
      proc do
        @document.script_runner&.call(source)
      rescue StandardError => e
        # The compiled script threw: reported like any script's exception.
        Internal::ExceptionReport.report_at(self, e)
      end
    end

    # WebIDL coercion for the `Text`/`Comment` constructor's `optional DOMString
    # data = ""`: an omitted or undefined argument uses the default (""), but an
    # explicit `null` stringifies to "null" per ToString. (Omitted arrives as an
    # empty args list; explicit JS null arrives as a Ruby nil element.)
    def node_data_arg(args)
      return "" if args.empty?

      value = args[0]
      return "" if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)
      return "null" if value.nil?
      # WebIDL ToString of an object: a crossed plain JS object arrives as a Hash;
      # run ToPrimitive(String) — its own `toString` then `valueOf` callback — so
      # `new Comment({toString: () => "x"})` yields "x" (and the second ctor
      # argument is never looked at, since only args[0] is coerced).
      return webidl_object_to_string(value) if value.is_a?(Hash)

      value.to_s
    end

    # ToPrimitive(object, String): invoke `toString`, then `valueOf`, using the
    # first that returns a primitive. A crossed JS function is a JS callable
    # (CallableInvoker.js_callable?). Falls back to "[object Object]".
    def webidl_object_to_string(hash)
      %w[toString valueOf].each do |name|
        cb = hash[name]
        next unless CallableInvoker.js_callable?(cb)

        result = CallableInvoker.invoke(cb)
        return result.to_s unless result.is_a?(Hash)
      end
      "[object Object]"
    end

  end

  # `window.locationbar` and the other bar objects. Every one is visible: no
  # browsing context Dommy models is a popup.
  class BarProp
    def initialize(window)
      @window = window
    end

    def visible = true

    def __js_get__(key)
      key == "visible" ? true : Bridge::ABSENT
    end
  end

  # `window.external`: the legacy search-provider hooks, which do nothing.
  class External
    include Bridge::Methods
    js_methods %w[AddSearchProvider IsSearchProviderInstalled]

    def __js_get__(_key) = Bridge::ABSENT

    def __js_call__(method, _args)
      case method
      when "AddSearchProvider", "IsSearchProviderInstalled"
        nil
      end
    end
  end
end
