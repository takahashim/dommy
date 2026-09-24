# frozen_string_literal: true

require_relative "internal/window_constructors"

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

    # Event handler IDL attributes the Window exposes (GlobalEventHandlers +
    # WindowEventHandlers). Setting one (`window.onload = fn`) registers a
    # listener; only these known names are intercepted so an arbitrary
    # on-prefixed global (`window.onboarding = {...}`) still stays a plain
    # expando rather than being mistaken for an event handler.
    WINDOW_EVENT_HANDLER_NAMES = %w[
      onabort onauxclick onbeforeinput onbeforematch onbeforetoggle onblur oncancel oncanplay
      oncanplaythrough onchange onclick onclose oncontextlost oncontextmenu oncontextrestored oncopy
      oncuechange oncut ondblclick ondrag ondragend ondragenter ondragleave ondragover ondragstart
      ondrop ondurationchange onemptied onended onerror onfocus onformdata oninput oninvalid onkeydown
      onkeypress onkeyup onload onloadeddata onloadedmetadata onloadstart onmousedown onmouseenter
      onmouseleave onmousemove onmouseout onmouseover onmouseup onpaste onpause onplay onplaying
      onprogress onratechange onreset onresize onscroll onscrollend onsecuritypolicyviolation onseeked
      onseeking onselect onslotchange onstalled onsubmit onsuspend ontimeupdate ontoggle onvolumechange
      onwaiting onwheel onafterprint onbeforeprint onbeforeunload onhashchange onlanguagechange onmessage
      onmessageerror onoffline ononline onpagehide onpageshow onpopstate onrejectionhandled onstorage
      onunhandledrejection onunload
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
      @location ? @location.__js_get__("origin").to_s : ""
    end

    # The child browsing contexts' windows, in document order — one per `<iframe>`
    # (nil for a frame whose content document isn't wired). Backs `window[i]` /
    # `window.frames[i]`.
    def frame_windows
      @document.query_selector_all("iframe").map do |frame|
        frame.respond_to?(:content_window) ? frame.content_window : nil
      end
    end

    # Optional WebSocket transport factory (a host seam, like the document's
    # external_script_runner): `->(ws, url, protocols) -> transport | nil`.
    # A returned transport owns the connection — WebSocket#send / #close
    # delegate to it, and it reports lifecycle back through the
    # __transport_*__ callbacks (on the page thread). nil falls back to the
    # in-memory stub (auto-open + __test_simulate_*__ seams).
    attr_accessor :websocket_connector

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
      @local_storage = Storage.new
      @session_storage = Storage.new
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
      when "window", "self", "parent", "top", "frames"
        # A top-level browsing context refers to itself for these. Returning the
        # window (not nil) lets `window === window.parent` and frame-walking
        # loops (e.g. testharness.js's `while (w != w.parent)`) terminate.
        self
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
        @local_storage
      when "sessionStorage"
        @session_storage
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
      when ->(k) { k.is_a?(String) && WINDOW_EVENT_HANDLER_NAMES.include?(k) }
        # An event handler IDL attribute: the registered handler, or null (not
        # undefined) when unset — matching the spec and Element's on* getter.
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
      # `window.onload = fn` (and the other window event handlers) registers a
      # listener rather than stashing an expando, so the handler actually fires.
      if key.is_a?(String) && WINDOW_EVENT_HANDLER_NAMES.include?(key)
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
      matchMedia getComputedStyle scroll scrollTo scrollBy resizeTo
      alert confirm prompt open reportError getSelection postMessage
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
        @scheduler.set_timeout(args[0], timer_delay(args[1]))
      when "clearTimeout"
        @scheduler.clear_timeout(args[0])
      when "setInterval"
        @scheduler.set_interval(args[0], timer_delay(args[1]))
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
        # A new browsing context cannot be opened headlessly, but the URL is
        # still parsed: one the parser rejects is a SyntaxError.
        url = args[0]
        if !url.nil? && !url.equal?(Bridge::UNDEFINED) && !url.to_s.empty? && __internal_parse_url__(url).nil?
          raise DOMException::SyntaxError, "Unable to open a window with invalid URL #{url.to_s.inspect}"
        end

        nil
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
        post_message(args[0])
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
          event = ErrorEvent.new("error", "message" => message, "error" => error_value,
            "filename" => filename, "lineno" => lineno, "colno" => colno, "cancelable" => true)
          !dispatch_event(event)
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
      event = PromiseRejectionEvent.new(
        "unhandledrejection", "promise" => promise, "reason" => reason_value, "cancelable" => true
      )
      return nil unless dispatch_event(event)

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
      dispatch_event(PromiseRejectionEvent.new(
        "rejectionhandled", "promise" => promise, "reason" => reason_value
      ))
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

    # Called by History#go and Location.href= to fire popstate /
    # hashchange events. Listeners registered on the Window via
    # `addEventListener("popstate"|"hashchange", cb)` receive them.
    def fire_popstate(state)
      # PopStateEvent exposes the entry's state as `event.state` (the spec
      # property). Routers (Turbo) branch on `event.state`.
      event = PopStateEvent.new("popstate", "state" => state)
      dispatch_event(event)
    end

    def fire_hashchange(old_url, new_url)
      event = HashChangeEvent.new("hashchange", "oldURL" => old_url.to_s, "newURL" => new_url.to_s)
      dispatch_event(event)
    end

    # Single firing point for cross-document navigation intents. Link
    # activation, location.assign/replace/reload and cross-boundary history
    # traversal all route here; the attached delegate (NullDelegate by default)
    # decides what happens. Same-document navigation never reaches this — it is
    # handled directly by Location/History (hashchange / popstate).
    def __internal_navigate__(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, headers: {}, replace: false)
      @navigation_delegate&.navigate(
        url: url, method: method, body: body, params: params, enctype: enctype,
        headers: headers, replace: replace, source: source
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

    # `window.postMessage`: deliver a structured-cloned `message` to this window's
    # own message handlers from a TASK (the "post message" task source, not a
    # microtask) — so it lands in a later event-loop turn, as the spec requires.
    def post_message(message)
      data = Dommy.structured_clone(message)
      @scheduler.set_timeout(proc { dispatch_event(MessageEvent.new("message", "data" => data)) }, 0)
      nil
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
    def timer_delay(value)
      return value if value.is_a?(Numeric)
      return value.to_i if value.is_a?(String) && value =~ /\A\s*-?\d+/

      0
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
    # first that returns a primitive. A crossed JS function is a HostCallback
    # (invoked via `__js_call__("call", ...)`). Falls back to "[object Object]".
    def webidl_object_to_string(hash)
      %w[toString valueOf].each do |name|
        cb = hash[name]
        next unless cb.respond_to?(:__js_call__)

        result = cb.__js_call__("call", [])
        return result.to_s unless result.is_a?(Hash)
      end
      "[object Object]"
    end

  end
end
