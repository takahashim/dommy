# frozen_string_literal: true

module Dommy
  module Internal
    # The catalogue of JS global constructors a Window exposes: `new Event(...)`,
    # `new URL(...)`, `new FormData(...)` and seventy-odd more, each as the block
    # that builds it.
    #
    # It is a table, not behaviour, which is why it is not in window.rb — where
    # it was a fifth of the file and the largest thing in it. Adding a
    # constructor is one line here.
    #
    # A few are built above the table rather than in it: those are the ones with
    # static methods (`URL.createObjectURL`, `AbortSignal.timeout`), which need a
    # receiver to hang them on. `Bridge::Constructor#define_class_method` chains,
    # so they could be inlined — they are hoisted so each stays one readable
    # paragraph.
    module WindowConstructors
      private

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
        "HashChangeEvent" => Bridge::Constructor.new { |args| HashChangeEvent.new(args[0], args[1]) },
        "SubmitEvent" => Bridge::Constructor.new { |args| SubmitEvent.new(args[0], args[1]) },
        "CloseEvent" => Bridge::Constructor.new { |args| CloseEvent.new(args[0], args[1]) },
        "UIEvent" => Bridge::Constructor.new { |args| UIEvent.new(args[0], args[1]) },
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
        "FormData" => Bridge::Constructor.new { |args| FormData.from_js(args) },
        "DOMParser" => Bridge::Constructor.new { |_args| DOMParser.new(self) },
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
        "StorageEvent" => Bridge::Constructor.new { |args| StorageEvent.new(args[0], args[1]) },
        "TextEvent" => Bridge::Constructor.new { |args| TextEvent.new(args[0], args[1]) },
        "DeviceMotionEvent" => Bridge::Constructor.new { |args| DeviceMotionEvent.new(args[0], args[1]) },
        "DeviceOrientationEvent" => Bridge::Constructor.new { |args| DeviceOrientationEvent.new(args[0], args[1]) },
        "Animation" => Bridge::Constructor.new { |args| Animation.new(args[0], args[1], window: win) },
        "KeyframeEffect" => Bridge::Constructor.new { |args| KeyframeEffect.new(args[0], args[1] || [], args[2]) },
        "TextEncoder" => Bridge::Constructor.new { |_args| TextEncoder.new },
        "TextDecoder" => Bridge::Constructor.new { |args| TextDecoder.new(args[0] || "utf-8", args[1]) },
        "IntersectionObserver" => Bridge::Constructor.new { |args| IntersectionObserver.new(args[0], args[1]) },
        "ResizeObserver" => Bridge::Constructor.new { |args| ResizeObserver.new(args[0]) },
        "PerformanceObserver" => Bridge::Constructor.new { |args| PerformanceObserver.new(args[0]) },
        "Request" => Bridge::Constructor.new { |args| Request.new(args[0], args[1], win) },
        "XMLHttpRequest" => Bridge::Constructor.new { |_args| XMLHttpRequest.new(win) },
        # Constructable Stylesheets (`new CSSStyleSheet()`) are used by web
        # components to prepare CSS before attaching it to a shadow root. They
        # have no owner node; CSSOM edits remain available even where
        # adoptedStyleSheets itself is not implemented yet.
        "CSSStyleSheet" => Bridge::Constructor.new { |_args| CSSStyleSheet.new },
        "FileReader" => Bridge::Constructor.new { |_args| FileReader.new(win) },
        "MessageChannel" => Bridge::Constructor.new { |_args| MessageChannel.new(win) },
        "BroadcastChannel" => Bridge::Constructor.new { |args| BroadcastChannel.new(win, args[0]) },
        "WebSocket" => Bridge::Constructor.new { |args| WebSocket.new(win, args[0], args[1]) },
        "EventSource" => Bridge::Constructor.new { |args| EventSource.new(win, args[0], args[1]) },
        "Notification" => notification,
        "Worker" => Bridge::Constructor.new { |args| Worker.new(win, args[0], args[1]) },
        "ReadableStream" => Bridge::Constructor.new { |args| ReadableStream.new(win, args[0], args[1]) },
        "WritableStream" => Bridge::Constructor.new { |args| WritableStream.new(win, args[0], args[1]) },
        "TransformStream" => Bridge::Constructor.new { |args| TransformStream.new(win, args[0], args[1], args[2]) },
        "CountQueuingStrategy" => Bridge::Constructor.new { |args| CountQueuingStrategy.new(args[0]) },
        "ByteLengthQueuingStrategy" => Bridge::Constructor.new { |args| ByteLengthQueuingStrategy.new(args[0]) },
        "TextEncoderStream" => Bridge::Constructor.new { |_args| TextEncoderStream.new(win) },
        "TextDecoderStream" => Bridge::Constructor.new { |args| TextDecoderStream.new(win, args[0] || "utf-8", args[1]) },
        "CompressionStream" => Bridge::Constructor.new { |args| CompressionStream.new(win, args[0]) },
        "DecompressionStream" => Bridge::Constructor.new { |args| DecompressionStream.new(win, args[0]) },
        "URLPattern" => Bridge::Constructor.new { |args| URLPattern.from_js(args) },
        "Range" => Bridge::Constructor.new { |_args| Range.new(@document) },
        "StaticRange" => Bridge::Constructor.new { |args| StaticRange.from_init(args[0]) },
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
          # new Option(text, value, defaultSelected, selected). A null/undefined
          # text or value is absent; defaultSelected sets the `selected` content
          # attribute; selected (4th arg) sets the selectedness directly.
          present = ->(v) { !v.nil? && !(defined?(Bridge::UNDEFINED) && v.equal?(Bridge::UNDEFINED)) }
          # WebIDL `boolean` conversion (JS truthiness): false / 0 / "" / null /
          # undefined / NaN are falsy — the rest (incl. "0", {}, []) are truthy.
          truthy = lambda do |v|
            return false unless present.call(v)
            return false if v == false || v == 0 || v == "" # rubocop:disable Lint/BooleanSymbol
            return false if v.respond_to?(:nan?) && v.nan?

            true
          end
          opt = win.document.create_element("option")
          opt.text = args[0].to_s if present.call(args[0]) && !args[0].to_s.empty?
          opt.value = args[1].to_s if args.length >= 2 && present.call(args[1])
          # defaultSelected sets the `selected` content attribute; then the 4th
          # argument sets selectedness (without dirtying it), per the constructor.
          opt.default_selected = true if truthy.call(args[2])
          opt.__internal_set_selectedness__(truthy.call(args[3]))
          opt
        },
      }
    end
    end
  end
end
