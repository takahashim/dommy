# frozen_string_literal: true

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
    include EventTarget

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

    def initialize(host = nil, backend_doc: nil)
      @host = host
      @scheduler = Scheduler.new
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
      when "event"
        # The legacy global current-event is *absent* (undefined, not null) when
        # no event is being dispatched, so feature detection like
        # `window.event === undefined` (React's getCurrentEventPriority) takes the
        # not-supported path instead of dereferencing null. An explicitly-set
        # value still wins.
        @globals.key?("event") ? @globals["event"] : Bridge::UNDEFINED
      when /\A\d+\z/
        # `window[i]` / `window.frames[i]` — the i-th child browsing context's
        # window (the i-th `<iframe>`'s contentWindow), or ABSENT past the end.
        frame = frame_windows[key.to_i]
        frame.nil? ? Bridge::ABSENT : frame
      else
        # A stashed global wins (even if its value is nil/null); a key never set
        # is genuinely absent → ABSENT so JS sees `undefined` and `"x" in window`
        # is false (feature detection like `isUndefined(window.Vue)` works).
        @globals.key?(key) ? @globals[key] : Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
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
        nil # headless: no dialog (happy-dom semantics)
      when "confirm"
        false # no user -> treated as "Cancel"
      when "prompt"
        nil # no user input
      when "open"
        nil # cannot open a new browsing context headlessly
      when "reportError"
        nil # swallow programmatic error reports (no uncaught surfacing here)
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

    # Called by History#go and Location.href= to fire popstate /
    # hashchange events. Listeners registered on the Window via
    # `addEventListener("popstate"|"hashchange", cb)` receive them.
    def fire_popstate(state)
      # PopStateEvent exposes the entry's state as `event.state` (the spec
      # property). Routers (Turbo) branch on `event.state`.
      event = PopStateEvent.new("popstate", "state" => state)
      dispatch_event(event)
    end

    def fire_hashchange(old_hash, new_hash)
      event = CustomEvent.new("hashchange", "detail" => {"oldURL" => old_hash, "newURL" => new_hash})
      dispatch_event(event)
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
      base = @document&.base_uri
      return url.to_s if base.to_s.empty?

      URI.join(base.to_s, url.to_s).to_s
    rescue URI::Error
      url.to_s
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

    # Virtual scroll position. There's no real layout, but tracking a logical
    # `(scrollX, scrollY)` makes scroll-dependent behaviour observable: scrollTo/
    # scroll set it absolutely, scrollBy relatively, and a `scroll` event fires on
    # change so observers (e.g. Turbo's ScrollObserver, which records the position
    # into history restoration data and replays it on back/forward) work.
    def scroll_to(*args)
      x, y = parse_scroll_args(args, @scroll_x || 0, @scroll_y || 0, relative: false)
      update_scroll(x, y)
    end

    def scroll_by(*args)
      x, y = parse_scroll_args(args, @scroll_x || 0, @scroll_y || 0, relative: true)
      update_scroll(x, y)
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

    # Build the JS-global constructor map. Blocks are lazy (run at `new X()`
    # time), so they may reference `win` / `@document` freely.
    def build_constructors
      win = self

      notification = Bridge::Constructor.new { |args| Notification.new(win, args[0], args[1]) }
      notification.define_class_method("requestPermission") { |args| Notification.request_permission(win, args[0]) }

      url = Bridge::Constructor.new { |args| URL.new(args[0], args[1]) }
      url.define_class_method("createObjectURL") { |args| URL.create_object_url(args[0]) }
      url.define_class_method("revokeObjectURL") { |args| URL.revoke_object_url(args[0]) }
      url.define_class_method("parse") { |args| URL.parse(args[0], args[1]) }
      url.define_class_method("canParse") { |args| URL.can_parse(args[0], args[1]) }

      # AbortSignal is not constructible (`new AbortSignal()` → TypeError); it is
      # exposed only for its static factories abort()/any()/timeout().
      abort_signal = Bridge::Constructor.new { |_args| raise Bridge::TypeError, "Illegal constructor" }
      abort_signal.define_class_method("abort") { |args| args.empty? ? AbortSignal.abort : AbortSignal.abort(args[0]) }
      abort_signal.define_class_method("any") { |args| AbortSignal.any(args[0]) }
      abort_signal.define_class_method("timeout") { |args| AbortSignal.timeout(args[0], scheduler: win.scheduler) }

      {
        # `new Document()` — a fresh empty document (content type application/xml
        # per the DOM Standard, so it behaves as a non-HTML document).
        "Document" => Bridge::Constructor.new do
          Document.new(nil, backend_doc: Backend.empty_xml_document).tap { |d| d.content_type = "application/xml" }
        end,
        # `new Text(data?)` / `new Comment(data?)` / `new DocumentFragment()` —
        # create the node in this window's associated document (DOM Standard).
        "Text" => Bridge::Constructor.new { |args| win.document.create_text_node(node_data_arg(args)) },
        "Comment" => Bridge::Constructor.new { |args| win.document.create_comment(node_data_arg(args)) },
        "DocumentFragment" => Bridge::Constructor.new { |_args| win.document.create_document_fragment },
        "Event" => Bridge::Constructor.new { |args| Event.new(args[0], args[1]) },
        "CustomEvent" => Bridge::Constructor.new { |args| CustomEvent.new(args[0], args[1]) },
        "MessageEvent" => Bridge::Constructor.new { |args| MessageEvent.new(args[0], args[1]) },
        "PopStateEvent" => Bridge::Constructor.new { |args| PopStateEvent.new(args[0], args[1]) },
        "CloseEvent" => Bridge::Constructor.new { |args| CloseEvent.new(args[0], args[1]) },
        "MouseEvent" => Bridge::Constructor.new { |args| MouseEvent.new(args[0], args[1]) },
        "KeyboardEvent" => Bridge::Constructor.new { |args| KeyboardEvent.new(args[0], args[1]) },
        "PromiseRejectionEvent" => Bridge::Constructor.new { |args| PromiseRejectionEvent.new(args[0], args[1]) },
        "ErrorEvent" => Bridge::Constructor.new { |args| ErrorEvent.new(args[0], args[1]) },
        "EventTarget" => Bridge::Constructor.new { |_args| StandaloneEventTarget.new },
        "Error" => Bridge::Constructor.new { |args| ErrorValue.new(args[0]) },
        # The host PromiseConstructor backs Ruby-side promises (fetch, the
        # scheduler bridge). It must NOT shadow the engine's native Promise on the
        # JS side, though — `window.Promise` is forced to globalThis.Promise in
        # host_runtime.js's exposeConstructorsOnWindow so feature detection
        # (core-js et al.) sees a real Promise (=== globalThis.Promise) and does
        # not swap in a polyfill whose microtasks the host can't flush.
        "Promise" => Bridge::PromiseConstructor.new(win),
        "MutationObserver" => Bridge::Constructor.new { |args| MutationObserver.new(win, args[0]) },
        "AbortController" => Bridge::Constructor.new { |_args| AbortController.new },
        "AbortSignal" => abort_signal,
        "Blob" => Bridge::Constructor.new { |args| Blob.new(args[0] || [], args[1] || {}, win) },
        "File" => Bridge::Constructor.new { |args| File.new(args[0] || [], args[1].to_s, args[2] || {}, win) },
        "FileList" => Bridge::Constructor.new { |args| FileList.new(args[0] || []) },
        "FormData" => Bridge::Constructor.new { |args| FormData.new(args[0]) },
        "DOMParser" => Bridge::Constructor.new { |_args| DOMParser.new },
        "XMLSerializer" => Bridge::Constructor.new { |_args| XMLSerializer.new },
        "URLSearchParams" => Bridge::Constructor.new { |args| URLSearchParams.new(args[0] || "") },
        "Headers" => Bridge::Constructor.new { |args| Headers.new(args[0] || {}) },
        "Response" => Bridge::Constructor.new { |args| Response.__construct__(win, args[0], args[1]) }
          .define_class_method("json") { |args| Response.__json__(win, args.length >= 1 ? args[0] : Bridge::UNDEFINED, args[1]) }
          .define_class_method("redirect") { |args| Response.__redirect__(win, args[0], args[1]) }
          .define_class_method("error") { |_args| Response.__error__(win) },
        "DataTransfer" => Bridge::Constructor.new { |args|
          opts = args[0] || {}
          DataTransfer.new(
            files: opts["files"] || opts[:files] || [],
            data: opts["data"] || opts[:data] || {}
          )
        },
        "DragEvent" => Bridge::Constructor.new { |args| DragEvent.new(args[0], args[1]) },
        "InputEvent" => Bridge::Constructor.new { |args| InputEvent.new(args[0], args[1]) },
        "PointerEvent" => Bridge::Constructor.new { |args| PointerEvent.new(args[0], args[1]) },
        "ProgressEvent" => Bridge::Constructor.new { |args| ProgressEvent.new(args[0], args[1]) },
        "Touch" => Bridge::Constructor.new { |args| Touch.new(args[0] || {}) },
        "TouchEvent" => Bridge::Constructor.new { |args| TouchEvent.new(args[0], args[1]) },
        "ClipboardEvent" => Bridge::Constructor.new { |args| ClipboardEvent.new(args[0], args[1]) },
        "CompositionEvent" => Bridge::Constructor.new { |args| CompositionEvent.new(args[0], args[1]) },
        "WheelEvent" => Bridge::Constructor.new { |args| WheelEvent.new(args[0], args[1]) },
        "FocusEvent" => Bridge::Constructor.new { |args| FocusEvent.new(args[0], args[1]) },
        "BeforeUnloadEvent" => Bridge::Constructor.new { |args| BeforeUnloadEvent.new(args[0] || "beforeunload", args[1]) },
        "Animation" => Bridge::Constructor.new { |args| Animation.new(args[0], args[1], window: win) },
        "KeyframeEffect" => Bridge::Constructor.new { |args| KeyframeEffect.new(args[0], args[1] || [], args[2]) },
        "TextEncoder" => Bridge::Constructor.new { |_args| TextEncoder.new },
        "TextDecoder" => Bridge::Constructor.new { |args| TextDecoder.new(args[0] || "utf-8", args[1]) },
        "IntersectionObserver" => Bridge::Constructor.new { |args| IntersectionObserver.new(args[0], args[1]) },
        "ResizeObserver" => Bridge::Constructor.new { |args| ResizeObserver.new(args[0]) },
        "PerformanceObserver" => Bridge::Constructor.new { |args| PerformanceObserver.new(args[0]) },
        "Request" => Bridge::Constructor.new { |args| Request.new(args[0], args[1]) },
        "XMLHttpRequest" => Bridge::Constructor.new { |_args| XMLHttpRequest.new(win) },
        "FileReader" => Bridge::Constructor.new { |_args| FileReader.new(win) },
        "MessageChannel" => Bridge::Constructor.new { |_args| MessageChannel.new(win) },
        "BroadcastChannel" => Bridge::Constructor.new { |args| BroadcastChannel.new(win, args[0]) },
        "WebSocket" => Bridge::Constructor.new { |args| WebSocket.new(win, args[0], args[1]) },
        "EventSource" => Bridge::Constructor.new { |args| EventSource.new(win, args[0], args[1]) },
        "Notification" => notification,
        "Worker" => Bridge::Constructor.new { |args| Worker.new(win, args[0], args[1]) },
        "ReadableStream" => Bridge::Constructor.new { |args| ReadableStream.new(win, args[0]) },
        "WritableStream" => Bridge::Constructor.new { |args| WritableStream.new(win, args[0]) },
        "TransformStream" => Bridge::Constructor.new { |args| TransformStream.new(win, args[0]) },
        "TextEncoderStream" => Bridge::Constructor.new { |_args| TextEncoderStream.new(win) },
        "TextDecoderStream" => Bridge::Constructor.new { |args| TextDecoderStream.new(win, args[0] || "utf-8", args[1]) },
        "CompressionStream" => Bridge::Constructor.new { |args| CompressionStream.new(win, args[0]) },
        "DecompressionStream" => Bridge::Constructor.new { |args| DecompressionStream.new(win, args[0]) },
        "URLPattern" => Bridge::Constructor.new { |args| URLPattern.new(args[0], args[1]) },
        "Range" => Bridge::Constructor.new { |_args| Range.new(@document) },
        "URL" => url,
        # Legacy named constructors (HTML `[LegacyFactoryFunction]`): each builds
        # the corresponding element. `new Image()` is `<img>`, `new Audio()` is
        # `<audio>` (preload="auto"), `new Option()` is `<option>`. The JS side
        # exposes the globals with the target interface's prototype so e.g.
        # `new Image() instanceof HTMLImageElement` holds.
        "Image" => Bridge::Constructor.new { |args|
          img = win.document.create_element("img")
          img.set_attribute("width", args[0].to_s) unless args[0].nil?
          img.set_attribute("height", args[1].to_s) unless args[1].nil?
          img
        },
        "Audio" => Bridge::Constructor.new { |args|
          audio = win.document.create_element("audio")
          audio.set_attribute("preload", "auto")
          audio.set_attribute("src", args[0].to_s) unless args[0].nil?
          audio
        },
        "Option" => Bridge::Constructor.new { |args|
          opt = win.document.create_element("option")
          opt.text = args[0].to_s unless args[0].nil? || args[0].to_s.empty?
          opt.value = args[1].to_s if args.length >= 2 && !args[1].nil?
          opt.selected = true if args[2] || args[3] # defaultSelected / selectedness
          opt
        },
      }
    end
  end
end
