# frozen_string_literal: true

require "json"

module Dommy
  # `XMLHttpRequest` polyfill. Consults the same stub maps that
  # `FetchFn` reads (`__fetchy_stub__` / `__resource_fetch_stub__` /
  # `__inject_fetch_stub__`) so a single set of fixtures drives both
  # `fetch(...)` and `new XMLHttpRequest()` style code.
  #
  # State transitions match the spec:
  #   UNSENT(0) → OPENED(1) → HEADERS_RECEIVED(2) → LOADING(3) → DONE(4)
  # Each transition fires `readystatechange`. `load` / `loadend` fire
  # on completion; `error` / `timeout` / `abort` fire on the
  # respective failure paths.
  #
  # Async requests resolve via the scheduler (a microtask, or a
  # `setTimeout` for stubs with `delay:`); sync requests
  # (`open(..., false)`) deliver inline so tests can read
  # `xhr.responseText` immediately.
  #
  # Spec: https://xhr.spec.whatwg.org/
  class XMLHttpRequest
    include EventTarget

    UNSENT = 0
    OPENED = 1
    HEADERS_RECEIVED = 2
    LOADING = 3
    DONE = 4

    INLINE_HANDLERS = %w[
      readystatechange
      loadstart
      load
      loadend
      progress
      error
      timeout
      abort
    ].freeze

    attr_reader(
      :ready_state,
      :status,
      :status_text,
      :response_url,
      :response_text,
      :response_xml,
      :response,
      :upload
    )

    attr_accessor :timeout, :with_credentials, :response_type

    def initialize(window)
      @window = window
      @timeout = 0
      @with_credentials = false
      @response_type = ""
      @generation = 0
      reset_state
      @inline_handlers = {}
      @upload = XMLHttpRequestUpload.new
    end

    # XHR §open. `method` is uppercased; `async` defaults to true.
    def open(method, url, async = true, _user = nil, _password = nil)
      reset_state
      @method = method.to_s.upcase
      # XHR resolves the request URL against the document base URL, like fetch.
      @url = @window.__internal_resolve_url__(url.to_s)
      @async = async.nil? ? true : !!async
      @request_headers = {}
      transition(OPENED)
      nil
    end

    def set_request_header(name, value)
      raise Error, "setRequestHeader called before open" if @ready_state != OPENED

      key = name.to_s
      existing = @request_headers[key]
      @request_headers[key] = existing ? "#{existing}, #{value}" : value.to_s
      nil
    end

    alias setRequestHeader set_request_header

    def send(body = nil)
      raise Error, "send called before open" if @ready_state != OPENED

      @request_body = body
      @sent = true
      @generation += 1
      gen = @generation
      dispatch_event(ProgressEvent.new("loadstart"))

      entry = lookup_stub
      track_globals

      if entry.nil?
        deliver(body: "not found", status: 404, status_text: "Not Found", headers: {})
        return nil
      end

      delay = entry["delay"]
      if delay && @async
        schedule_delivery_with_delay(entry, delay.to_i, gen)
      elsif @async
        @window.scheduler.queue_microtask(proc { deliver_entry(entry) if active?(gen) })
      else
        deliver_entry(entry)
      end

      nil
    end

    def abort
      return if @ready_state == UNSENT || @ready_state == DONE
      # WHATWG: abort() is a no-op when in OPENED with the send()
      # flag unset. Without this guard, `xhr.open(); xhr.abort()`
      # would fire abort + loadend even though no request is
      # in flight.
      return if @ready_state == OPENED && !@sent

      @aborted = true
      @generation += 1
      @status = 0
      @status_text = ""
      transition(DONE)
      dispatch_event(ProgressEvent.new("abort"))
      dispatch_event(ProgressEvent.new("loadend"))
      reset_state(keep_handlers: true, keep_generation: true)
      nil
    end

    def get_response_header(name)
      return nil if @ready_state < HEADERS_RECEIVED

      key = name.to_s.downcase
      hit = @response_headers.find { |k, _| k.to_s.downcase == key }
      hit ? hit.last : nil
    end

    alias getResponseHeader get_response_header

    def get_all_response_headers
      return "" if @ready_state < HEADERS_RECEIVED

      @response_headers.map { |k, v| "#{k}: #{v}\r\n" }.join
    end

    alias getAllResponseHeaders get_all_response_headers

    def override_mime_type(mime)
      @override_mime = mime.to_s
      nil
    end

    alias overrideMimeType override_mime_type

    # --- JS bridge ---------------------------------------------------

    def __js_get__(key)
      case key
      when "readyState"
        @ready_state
      when "status"
        @status
      when "statusText"
        @status_text
      when "responseURL"
        @response_url
      when "response"
        @response
      when "responseText"
        @response_text
      when "responseXML"
        @response_xml
      when "responseType"
        @response_type
      when "timeout"
        @timeout
      when "withCredentials"
        @with_credentials
      when "upload"
        @upload
      when "UNSENT"
        UNSENT
      when "OPENED"
        OPENED
      when "HEADERS_RECEIVED"
        HEADERS_RECEIVED
      when "LOADING"
        LOADING
      when "DONE"
        DONE
      else
        @inline_handlers[inline_event_for(key)]
      end
    end

    def __js_set__(key, value)
      case key
      when "responseType"
        @response_type = value.to_s
      when "timeout"
        @timeout = value.to_i
      when "withCredentials"
        @with_credentials = !!value
      else
        event = inline_event_for(key)
        return Bridge::UNHANDLED unless event

        set_inline_handler(event, value)
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[
      open send setRequestHeader abort getResponseHeader getAllResponseHeaders overrideMimeType
      addEventListener removeEventListener dispatchEvent
    ]
    def __js_call__(method, args)
      case method
      when "open"
        open(args[0], args[1], args[2].nil? ? true : args[2], args[3], args[4])
      when "send"
        send(args[0])
      when "setRequestHeader"
        set_request_header(args[0], args[1])
      when "abort"
        abort
      when "getResponseHeader"
        get_response_header(args[0])
      when "getAllResponseHeaders"
        get_all_response_headers
      when "overrideMimeType"
        override_mime_type(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end

    class Error < StandardError
    end

    private

    def reset_state(keep_handlers: false, keep_generation: false)
      @ready_state = UNSENT
      @status = 0
      @status_text = ""
      @response_url = ""
      @response = nil
      @response_text = ""
      @response_xml = nil
      @response_headers = {}
      @request_headers = {}
      @aborted = false unless keep_generation
      @sent = false
      @override_mime = nil
      @method = nil
      @url = nil
      @async = true
      @inline_handlers = {} unless keep_handlers
      @generation = 0 unless keep_generation
    end

    # A queued delivery is "active" only if no abort / reopen has
    # bumped the generation since its send() call.
    def active?(gen)
      @generation == gen && !@aborted
    end

    def transition(state)
      @ready_state = state
      dispatch_event(Event.new("readystatechange"))
    end

    def lookup_stub
      # Same resolution order as FetchFn: a `__fetch_handler__` callable
      # (e.g. dommy-rack's NetworkBridge serving same-origin requests from
      # the Rack app) gets first refusal; nil falls through to the stubs.
      handler = @window.globals["__fetch_handler__"]
      if handler.respond_to?(:call)
        entry = handler.call(
          @url,
          {"method" => @method, "headers" => @request_headers, "body" => @request_body&.to_s}
        )
        return entry if entry
      end

      stub_map = @window.globals["__fetchy_stub__"] ||
        @window.globals["__resource_fetch_stub__"] ||
        @window.globals["__inject_fetch_stub__"]
      return nil unless stub_map.is_a?(Hash)

      stub_map[@url] || stub_map[@window.__internal_url_path__(@url)]
    end

    # Bookkeeping that lets specs assert "fetch was called N times"
    # uniformly across `fetch` and XHR (`FetchFn` writes the same
    # globals; XHR mirrors them).
    def track_globals
      @window.globals["__fetch_count__"] = (@window.globals["__fetch_count__"] || 0).to_i + 1
      @window.globals["__last_url__"] = @url
      @window.globals["__last_method__"] = @method
      @window.globals["__last_body__"] = @request_body
    end

    def schedule_delivery_with_delay(entry, delay_ms, gen)
      timer = @window.scheduler.set_timeout(
        proc { deliver_entry(entry) if active?(gen) },
        delay_ms
      )

      return unless @timeout.to_i.positive?

      @window.scheduler.set_timeout(
        proc {
          next unless active?(gen)
          next if @ready_state == DONE

          @window.scheduler.clear_timeout(timer)
          fail_with("timeout")
        },
        @timeout
      )
    end

    def deliver_entry(entry)
      body = entry["body"].to_s
      status = (entry["status"] || 200).to_i
      status_text = entry["statusText"] || ""
      headers = entry["headers"] || {"Content-Type" => entry["contentType"] || "text/plain"}
      deliver(body: body, status: status, status_text: status_text, headers: headers)
    end

    def deliver(body:, status:, status_text:, headers:)
      return if @aborted

      @status = status
      @status_text = status_text
      @response_headers = headers
      @response_url = @url
      @response_text = body
      @response = decode_response(body)

      transition(HEADERS_RECEIVED)
      transition(LOADING)
      transition(DONE)
      dispatch_event(ProgressEvent.new("load"))
      dispatch_event(ProgressEvent.new("loadend"))
    end

    def fail_with(reason)
      @status = 0
      @status_text = ""
      transition(DONE)
      dispatch_event(ProgressEvent.new(reason))
      dispatch_event(ProgressEvent.new("loadend"))
    end

    # Decode the body into `response` per `responseType`.
    def decode_response(body)
      case @response_type
      when "", "text"
        body
      when "json"
        begin
          JSON.parse(body)
        rescue JSON::ParserError
          nil
        end

      when "arraybuffer"
        # responseType "arraybuffer" yields a real ArrayBuffer.
        Bridge::ArrayBuffer.new(body.bytes)
      when "blob"
        Blob.new([body], {"type" => response_content_type}, @window)
      when "document"
        parse_document(body)
      else
        body
      end
    end

    # Content-Type of the received response, read straight from
    # `@response_headers` (not `get_response_header`, which gates on
    # `readyState` — decode runs before that flag advances).
    def response_content_type
      hit = @response_headers.find { |k, _| k.to_s.downcase == "content-type" }
      hit ? hit.last.to_s : ""
    end

    def parse_document(body)
      DOMParser.new.parse_from_string(body, "text/html")
    rescue StandardError
      nil
    end

    INLINE_EVENT_MAP = INLINE_HANDLERS
      .each_with_object({}) do |name, h|
        h["on#{name}"] = name
      end
      .freeze

    def inline_event_for(key)
      INLINE_EVENT_MAP[key.to_s]
    end

    def set_inline_handler(event, handler)
      previous = @inline_handlers[event]
      remove_event_listener(event, previous) if previous

      if handler.nil?
        @inline_handlers.delete(event)
      else
        add_event_listener(event, handler)
        @inline_handlers[event] = handler
      end
    end
  end

  # `XMLHttpRequestUpload` — the upload-side event target. Real
  # browsers fire `progress` here while uploading multipart bodies;
  # dommy doesn't simulate upload, so this is an inert EventTarget
  # the caller can still `addEventListener` against.
  class XMLHttpRequestUpload
    include EventTarget

    include Bridge::Methods
    js_methods %w[addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end
  end
end
