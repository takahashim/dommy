# frozen_string_literal: true

require "cgi"
require "erb"

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

    attr_reader :document, :scheduler, :location, :globals, :custom_elements, :navigator

    def initialize(host = nil, nokogiri_doc: nil)
      @host = host
      @scheduler = Scheduler.new
      @event_ctor = Bridge::Constructor.new { |args| Event.new(args[0], args[1]) }
      @custom_event_ctor = Bridge::Constructor.new { |args| CustomEvent.new(args[0], args[1]) }
      @mouse_event_ctor = Bridge::Constructor.new { |args| MouseEvent.new(args[0], args[1]) }
      @keyboard_event_ctor = Bridge::Constructor.new { |args| KeyboardEvent.new(args[0], args[1]) }
      @event_target_ctor = Bridge::Constructor.new { |_args| StandaloneEventTarget.new }
      @error_ctor = Bridge::Constructor.new { |args| ErrorValue.new(args[0]) }
      @promise_ctor = Bridge::PromiseConstructor.new(self)
      @mutation_observer_ctor = Bridge::Constructor.new { |args| MutationObserver.new(self, args[0]) }
      @abort_controller_ctor = Bridge::Constructor.new { |_args| AbortController.new }
      @blob_ctor = Bridge::Constructor.new { |args| Blob.new(args[0] || [], args[1] || {}) }
      @file_ctor = Bridge::Constructor.new { |args| File.new(args[0] || [], args[1].to_s, args[2] || {}) }
      @file_list_ctor = Bridge::Constructor.new { |args| FileList.new(args[0] || []) }
      @data_transfer_ctor = Bridge::Constructor.new { |args|
        opts = args[0] || {}
        DataTransfer.new(
          files: opts["files"] || opts[:files] || [],
          data: opts["data"] || opts[:data] || {}
        )
      }
      @drag_event_ctor = Bridge::Constructor.new { |args| DragEvent.new(args[0], args[1]) }
      @input_event_ctor = Bridge::Constructor.new { |args| InputEvent.new(args[0], args[1]) }
      @pointer_event_ctor = Bridge::Constructor.new { |args| PointerEvent.new(args[0], args[1]) }
      @progress_event_ctor = Bridge::Constructor.new { |args| ProgressEvent.new(args[0], args[1]) }
      @touch_ctor = Bridge::Constructor.new { |args| Touch.new(args[0] || {}) }
      @touch_event_ctor = Bridge::Constructor.new { |args| TouchEvent.new(args[0], args[1]) }
      @clipboard_event_ctor = Bridge::Constructor.new { |args| ClipboardEvent.new(args[0], args[1]) }
      @composition_event_ctor = Bridge::Constructor.new { |args| CompositionEvent.new(args[0], args[1]) }
      @wheel_event_ctor = Bridge::Constructor.new { |args| WheelEvent.new(args[0], args[1]) }
      @focus_event_ctor = Bridge::Constructor.new { |args| FocusEvent.new(args[0], args[1]) }
      @before_unload_event_ctor = Bridge::Constructor.new { |args|
        BeforeUnloadEvent.new(args[0] || "beforeunload", args[1])
      }
      win_ref = self
      @animation_ctor = Bridge::Constructor.new { |args| Animation.new(args[0], args[1], window: win_ref) }
      @keyframe_effect_ctor = Bridge::Constructor.new { |args| KeyframeEffect.new(args[0], args[1] || [], args[2]) }
      @crypto = Crypto.new
      @text_encoder_ctor = Bridge::Constructor.new { |_args| TextEncoder.new }
      @text_decoder_ctor = Bridge::Constructor.new { |args| TextDecoder.new(args[0] || "utf-8", args[1]) }
      @intersection_observer_ctor = Bridge::Constructor.new { |args| IntersectionObserver.new(args[0], args[1]) }
      @resize_observer_ctor = Bridge::Constructor.new { |args| ResizeObserver.new(args[0]) }
      @performance_observer_ctor = Bridge::Constructor.new { |args| PerformanceObserver.new(args[0]) }
      @request_ctor = Bridge::Constructor.new { |args| Request.new(args[0], args[1]) }
      @range_ctor = Bridge::Constructor.new { |_args| Range.new(@document) }
      @local_storage = Storage.new
      @session_storage = Storage.new
      @location = Location.new(self)
      @history = History.new(self, @location)
      @url_ctor = Bridge::Constructor.new { |args| URL.new(args[0], args[1]) }
      @url_ctor.define_class_method("createObjectURL") { |args| URL.create_object_url(args[0]) }
      @url_ctor.define_class_method("revokeObjectURL") { |args| URL.revoke_object_url(args[0]) }
      # `JS.global[:__some_key__] = ...` from user code lands here.
      # Test code uses this for stub installation (e.g. a custom
      # `__fetch_stub__`); production code stays on the typed
      # accessors above. We keep it last in the read fallback to
      # avoid shadowing intentional getters.
      @globals = {}
      @document = Document.new(host, nokogiri_doc: nokogiri_doc)
      @document.default_view = self
      @custom_elements = CustomElementRegistry.new(self)
      @navigator = Navigator.new(self)
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
      case key
      when "document"
        @document
      when "Event"
        @event_ctor
      when "CustomEvent"
        @custom_event_ctor
      when "MouseEvent"
        @mouse_event_ctor
      when "KeyboardEvent"
        @keyboard_event_ctor
      when "EventTarget"
        @event_target_ctor
      when "Error"
        @error_ctor
      when "Promise"
        @promise_ctor
      when "MutationObserver"
        @mutation_observer_ctor
      when "AbortController"
        @abort_controller_ctor
      when "Blob"
        @blob_ctor
      when "File"
        @file_ctor
      when "FileList"
        @file_list_ctor
      when "DataTransfer"
        @data_transfer_ctor
      when "DragEvent"
        @drag_event_ctor
      when "InputEvent"
        @input_event_ctor
      when "PointerEvent"
        @pointer_event_ctor
      when "ProgressEvent"
        @progress_event_ctor
      when "Touch"
        @touch_ctor
      when "TouchEvent"
        @touch_event_ctor
      when "ClipboardEvent"
        @clipboard_event_ctor
      when "CompositionEvent"
        @composition_event_ctor
      when "WheelEvent"
        @wheel_event_ctor
      when "FocusEvent"
        @focus_event_ctor
      when "BeforeUnloadEvent"
        @before_unload_event_ctor
      when "Animation"
        @animation_ctor
      when "KeyframeEffect"
        @keyframe_effect_ctor
      when "crypto"
        @crypto
      when "TextEncoder"
        @text_encoder_ctor
      when "TextDecoder"
        @text_decoder_ctor
      when "IntersectionObserver"
        @intersection_observer_ctor
      when "ResizeObserver"
        @resize_observer_ctor
      when "PerformanceObserver"
        @performance_observer_ctor
      when "Request"
        @request_ctor
      when "Range"
        @range_ctor
        # handled by Symbol sentinel
      when "console"
        :console
        # likewise
      when "Object"
        :object_ctor
      when "Array"
        :array_ctor
      when "JSON"
        :json_ctor
      when "performance"
        {"now" => @scheduler.now_ms.to_f}
      when "localStorage"
        @local_storage
      when "sessionStorage"
        @session_storage
      when "location"
        @location
      when "history"
        @history
      when "URL"
        @url_ctor
      when "fetch"
        FetchFn.new(self)
      when "customElements"
        @custom_elements
      when "navigator"
        @navigator
      else
        @globals[key]
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

    def __js_call__(method, args)
      case method
      when "fetch"
        FetchFn.new(self).__js_call__("call", args)
      when "encodeURIComponent"
        # JS spec encoding: percent-encode anything except
        # `A-Za-z0-9 - _ . ! ~ * ' ( )`. Ruby's `CGI.escape` uses
        # `+` for space; ERB::Util.url_encode matches JS behavior.
        ERB::Util.url_encode(args[0].to_s)
      when "decodeURIComponent"
        CGI.unescape(args[0].to_s)
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "setTimeout"
        @scheduler.set_timeout(args[0], args[1] || 0)
      when "clearTimeout"
        @scheduler.clear_timeout(args[0])
      when "setInterval"
        @scheduler.set_interval(args[0], args[1] || 0)
      when "clearInterval"
        @scheduler.clear_interval(args[0])
      when "requestAnimationFrame"
        @scheduler.request_animation_frame(args[0])
      when "cancelAnimationFrame"
        @scheduler.cancel_animation_frame(args[0])
      when "queueMicrotask"
        @scheduler.queue_microtask(args[0])
      else
        # Additional window-level methods (fetch, location, history,
        # Promise, MutationObserver, etc.) arrive in later sessions.
        nil
      end
    end

    def __event_parent__
      nil
    end

    # Called by History#go and Location.href= to fire popstate /
    # hashchange events. Listeners registered on the Window via
    # `addEventListener("popstate"|"hashchange", cb)` receive them.
    def fire_popstate(state)
      event = CustomEvent.new("popstate", "detail" => state)
      dispatch_event(event)
    end

    def fire_hashchange(old_hash, new_hash)
      event = CustomEvent.new("hashchange", "detail" => {"oldURL" => old_hash, "newURL" => new_hash})
      dispatch_event(event)
    end
  end
end
