# frozen_string_literal: true

require "uri"

module Dommy
  module Rack
    # A structured, virtual-time-ordered record of what a Session did: user
    # actions, HTTP exchanges (each redirect hop included), document loads,
    # script boots, console output, JS errors, and — opt-in — DOM mutations.
    # One ordered event stream, not a log: it powers readable failure reports
    # and machine-readable diagnostics (`to_text` / `to_ndjson`).
    #
    #   session = Dommy::Rack::Session.new(app, trace: true)
    #   session.visit "/login"
    #   session.click_button "Login"
    #   puts session.trace.to_text
    #
    # The Trace subscribes to the Session's request/response/document seams and,
    # when JS is enabled, to the SessionRuntime's console/js_error/script seams.
    # User-action grouping comes from the Session's navigation verbs calling
    # `__internal_open_action` (the shared field verbs are intentionally not
    # instrumented). `seq` — assigned at emit time — is the authoritative
    # timeline order; `t` is the virtual clock (nil before a document exists).
    class Trace
      # An event's kind. `:action` opens a user-action group that following
      # events reference via `action_seq`. `:http` covers one request/response
      # (a 3xx hop carries `location`, so the redirect chain is just successive
      # `:http` events).
      # `t` is the virtual clock (nil before a window exists); `wall_ms` is real
      # monotonic milliseconds since the trace started, for spotting slow steps.
      Event = Struct.new(:seq, :t, :wall_ms, :type, :name, :action_seq, :data, keyword_init: true)

      # Recording verbosity. `:off` records nothing; `:actions` records the
      # action / http / form / document / dom timeline; `:verbose` adds the
      # JS-realm streams (script / console / js_error).
      LEVELS = %i[off actions verbose].freeze
      REALM_TYPES = %i[script console js_error].freeze

      # Build a Trace, wire it to the session's (and its runtime's) seams, and
      # return it. A `:off` trace wires nothing.
      def self.attach(session, level: :verbose, dom: false, filter: ParamFilter::DEFAULT, snapshots: false)
        trace = new(session, level: level, dom: dom, filter: filter, snapshots: snapshots)
        trace.__internal_wire
        trace
      end

      attr_reader :events, :level, :artifacts

      def initialize(session, level: :verbose, dom: false, filter: ParamFilter::DEFAULT, snapshots: false)
        @session = session
        @level = LEVELS.include?(level) ? level : :verbose
        @dom = dom
        @param_filter = ParamFilter.new(filter)
        @snapshots = snapshots
        @events = []
        @artifacts = {} # seq => captured content (e.g. DOM HTML), kept out of the event
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @seq = 0
        @action_seq = nil
        @pending_request = nil
        @observers = []
      end

      # Subscribe to the session and (when present) runtime seams. Called by
      # `.attach`; safe to call once.
      def __internal_wire
        return if @level == :off

        @session.on_request { |env| __internal_on_request(env) }
        @session.on_response { |response| __internal_on_response(response) }
        @session.on_abort { |env| __internal_on_abort(env) } if @session.respond_to?(:on_abort)

        runtime = @session.respond_to?(:__internal_js_runtime) ? @session.__internal_js_runtime : nil
        if runtime
          runtime.on_document { |window| __internal_on_document(window) }
          runtime.on_script { |element, error| __internal_emit(:script, script_data(element, error), window: current_window) }
          runtime.on_console { |log| __internal_emit(:console, console_data(log), window: current_window) }
          runtime.on_js_error { |error| __internal_emit(:js_error, {message: error_message(error)}, window: current_window) }
        else
          @session.on_document_loaded { |window| __internal_on_document(window) }
        end
        nil
      end

      # --- Seams the Session's navigation verbs call directly ---

      # Open a user-action group. Following events carry this action's `seq` as
      # their `action_seq` until the next action opens.
      def __internal_open_action(verb, label = nil)
        return if @level == :off

        @seq += 1
        @action_seq = @seq
        event = Event.new(seq: @seq, t: now_ms, wall_ms: monotonic_ms, type: :action, name: verb,
          action_seq: nil, data: {verb: verb, label: label, source: __internal_caller_source})
        @events << event
        __internal_stream(event)
        nil
      end

      def record_error(message:, exception_class: nil, source: nil)
        data = {exception_class: exception_class, message: presence(message)}.compact
        __internal_emit(:error, {label: "Expectation failed", source: source, data: data}.compact,
          window: current_window)
      end

      # Record a form submission (method, path, filtered params). Form params
      # arrive as ordered [name, value] pairs; present them as a masked hash.
      def __internal_record_form(method:, url:, params: nil)
        __internal_emit(:form, {method: method, path: path_of(url) || url, params: @param_filter.form_params(params)})
      end

      # Drain the current window's microtasks so queued MutationObserver records
      # are delivered (JS mode does this via after_interaction; non-JS / tests
      # call this explicitly).
      def flush_dom
        return unless @dom

        current_window&.scheduler&.drain_microtasks
        nil
      end

      # The configured sensitive-key filter — instrumentation layers mask
      # values they record (SQL binds) with the SAME rules as form params.
      def __internal_param_filter__ = @param_filter

      # --- Queries (read-only views over the event stream) ---

      def http = events_of(:http)
      def documents = events_of(:document)
      def scripts = events_of(:script)
      def console = events_of(:console)
      def js_errors = events_of(:js_error)
      def forms = events_of(:form)
      def actions = events_of(:action)
      def dom_mutations = events_of(:dom)
      def last_action = actions.last
      def recent(count = 10) = @events.last(count)

      # The page currently loaded (for failure context).
      def current_page = {url: @session.current_url, title: @session.document&.title}

      # --- Formatting ---

      def to_text(limit: nil) = Formatter::Text.new(limit ? @events.last(limit) : @events).render
      def to_s = to_text

      def to_ndjson(status: "ok", wall_time: nil, metadata: nil)
        inline = @artifacts.transform_values { |content| {content: content, encoding: "utf-8"} }
        Ndjson.new(@events, level: @level, wall_time: wall_time, metadata: metadata,
          artifacts: inline, end_wall_ms: monotonic_ms).document(status: status)
      end

      def write_ndjson(path, **opts)
        ::File.write(path, to_ndjson(**opts))
      end

      # Write a self-contained trace bundle to `dir`: `trace.ndjson` plus an
      # `artifacts/` directory with each captured snapshot as its own file, the
      # NDJSON referencing them by relative path. Returns `dir`. This is what the
      # standalone viewer opens (and `v`/`o` resolve paths against).
      def save(dir, status: "ok", metadata: nil)
        require "fileutils"
        ::FileUtils.mkdir_p(::File.join(dir, "artifacts"))
        paths = @artifacts.each_with_object({}) do |(seq, content), out|
          rel = ::File.join("artifacts", "art_#{seq}.html")
          ::File.write(::File.join(dir, rel), content)
          out[seq] = {path: rel}
        end
        ndjson = Ndjson.new(@events, level: @level, metadata: metadata,
          artifacts: paths, end_wall_ms: monotonic_ms).document(status: status)
        ::File.write(::File.join(dir, "trace.ndjson"), ndjson)
        dir
      end

      # Stream every event as an NDJSON line the moment it is recorded —
      # append-only, one flush per line — so a live viewer (dommylizer
      # --follow) tails the run, and a hang or kill still leaves the trace up
      # to the last completed event. Accepts an IO or a path (opened for
      # write; closed by #finish_stream). Bracket with #finish_stream to add
      # the trace_end line.
      #
      #   session.trace.stream_to("tmp/live.trace.ndjson")
      #   ... drive the session ...
      #   session.trace.finish_stream(status: "ok")
      def stream_to(path_or_io, metadata: nil)
        require "json"
        @stream_owns_io = !path_or_io.respond_to?(:write)
        io = @stream_owns_io ? ::File.open(path_or_io, "w") : path_or_io
        @stream_serializer = Ndjson.new(@events, level: @level, metadata: metadata,
          artifacts: StreamingArtifacts.new(@artifacts))
        io.write(::JSON.generate(@stream_serializer.start_line), "\n")
        io.flush if io.respond_to?(:flush)
        @stream_io = io
        self
      end

      def finish_stream(status: "ok")
        io = @stream_io
        return nil unless io

        @stream_io = nil
        io.write(::JSON.generate(@stream_serializer.end_line(status.to_s)), "\n")
        io.flush if io.respond_to?(:flush)
        io.close if @stream_owns_io
        nil
      end

      # Resolves an artifact's emission fields at WRITE time (the content is
      # captured in the same synchronous flow, just before the event lands).
      class StreamingArtifacts
        def initialize(artifacts)
          @artifacts = artifacts
        end

        def [](seq)
          content = @artifacts[seq]
          content ? {content: content, encoding: "utf-8"} : nil
        end
      end

      private

      # Emit one event, gated by the recording level, and return it (or nil if
      # gated out). `seq` is the canonical order; `t` is the virtual clock if a
      # window exists.
      # `artifact:` carries the event's captured content (a DOM snapshot); it
      # is stored BEFORE the event streams, so a live stream's write-time
      # lookup (StreamingArtifacts) sees it.
      def __internal_emit(type, data, name: nil, window: nil, artifact: nil)
        return if @level == :off
        return if REALM_TYPES.include?(type) && @level != :verbose

        @seq += 1
        event = Event.new(seq: @seq, t: window&.scheduler&.now_ms, wall_ms: monotonic_ms, type: type,
          name: name, action_seq: @action_seq, data: data)
        @artifacts[event.seq] = artifact if artifact
        @events << event
        __internal_stream(event)
        event
      end

      # A dead stream (closed pipe, full disk) must not take the session down:
      # drop the stream and keep tracing in memory.
      def __internal_stream(event)
        return unless @stream_io

        @stream_io.write(::JSON.generate(@stream_serializer.event_line(event)), "\n")
        @stream_io.flush if @stream_io.respond_to?(:flush)
      rescue StandardError
        @stream_io = nil
      end

      # on_request fires before its on_response (single-threaded, per redirect
      # hop), so stash the method/path here and emit the `:http` event when the
      # response arrives with its status.
      def __internal_on_request(env)
        @pending_request = {
          method: env["REQUEST_METHOD"],
          path: env["PATH_INFO"],
          query: presence(env["QUERY_STRING"])
        }
        # Expose this trace to in-app instrumentation (dommy-rails subscribes
        # to ActiveSupport::Notifications and buffers spans here) for the
        # duration of the request. Requests run synchronously on this thread.
        @pending_spans = []
        Thread.current[:__dommy_active_trace__] = self
        nil
      end

      def __internal_on_response(response)
        request = @pending_request || {}
        @pending_request = nil
        Thread.current[:__dommy_active_trace__] = nil
        http = __internal_emit(:http, {
          method: request[:method],
          path: request[:path] || path_of(response.url),
          query: request[:query],
          status: response.status,
          content_type: response.content_type,
          location: response.location_header,
          set_cookie: response.set_cookie_strings.map { |raw| cookie_name(raw) }
        })
        __internal_flush_spans(http)
      end

      # The request never produced a Response (the app raised): close the
      # bracket on_request opened — clear the thread-local and record the
      # aborted request itself (its buffered spans, if any, attach to it so
      # the trace shows what ran before the exception).
      def __internal_on_abort(env)
        request = @pending_request || {}
        @pending_request = nil
        Thread.current[:__dommy_active_trace__] = nil
        http = __internal_emit(:http, {
          method: request[:method] || env["REQUEST_METHOD"],
          path: request[:path] || env["PATH_INFO"],
          query: request[:query],
          status: nil,
          aborted: true
        })
        __internal_flush_spans(http)
      end

      # Buffer an inside-the-request span (controller/db/render — anything an
      # instrumentation layer measured). Emitted as completed span events,
      # parented to the enclosing :http event, when the response arrives —
      # spans finish before the response exists, so they can't reference it
      # any earlier.
      def __internal_record_span__(kind:, label:, duration_ms:, data: nil)
        return if @level == :off || @pending_spans.nil?

        @pending_spans << {kind: kind.to_s, label: label.to_s,
                           duration_ms: duration_ms.to_f.round(2), data: data}
        nil
      end
      # The instrumentation entry point (reached via the thread-local) must be
      # callable from outside; the surrounding seams stay private.
      public :__internal_record_span__

      def __internal_flush_spans(http_event)
        spans = @pending_spans
        @pending_spans = nil
        return if spans.nil? || spans.empty? || http_event.nil?

        spans.each do |span|
          payload = {kind: span[:kind], label: span[:label],
                     duration_ms: span[:duration_ms], parent: http_event.seq}
          payload.merge!(span[:data]) if span[:data]
          __internal_emit(:span, payload)
        end
        nil
      end

      def __internal_on_document(window)
        __internal_emit(:document, {url: @session.current_url, title: window&.document&.title}, window: window)
        __internal_setup_dom_observer(window) if @dom
        __internal_snapshot_dom(window) if @snapshots
      end

      # Capture the loaded document's HTML as a dom_snapshot artifact.
      def __internal_snapshot_dom(window)
        html = @session.document&.to_html
        return unless html

        __internal_emit(:artifact,
          {kind: "dom_snapshot", label: "DOM #{@session.current_url}", content_type: "text/html"},
          window: window, artifact: html)
      end

      # --- DOM observation ---

      def __internal_setup_dom_observer(window)
        @observers << DomObserver.new(window) { |summary| __internal_emit_dom(summary, current_window) }
        nil
      end

      # Emit a `:dom` event, coalescing a run of same-target/same-op mutations
      # into one entry (Turbo morphs would otherwise flood the trace).
      def __internal_emit_dom(summary, window)
        last = @events.last
        if last && last.type == :dom && last.data[:op] == summary[:op] && last.data[:target] == summary[:target]
          last.data[:count] = (last.data[:count] || 1) + (summary[:count] || 1)
          return
        end
        __internal_emit(:dom, summary, window: window)
      end

      # --- Data extraction helpers (defensive: the JS backend lives elsewhere,
      # so console/error shapes are not assumed) ---

      def script_data(element, error)
        src = element.respond_to?(:get_attribute) ? element.get_attribute("src") : nil
        {src: presence(src), inline: presence(src).nil?, ok: error.nil?, error: error && error_message(error)}
      end

      def console_data(log)
        return {level: log.level, text: log.text} if log.respond_to?(:level) && log.respond_to?(:text)
        return {level: log[:level] || log["level"], text: log[:text] || log["text"] || log.to_s} if log.is_a?(Hash)

        {level: nil, text: log.to_s}
      end

      def error_message(error)
        error.respond_to?(:message) ? error.message : error.to_s
      end

      def current_window = @session.document&.default_view
      def now_ms = current_window&.scheduler&.now_ms

      # Real monotonic milliseconds since the trace started.
      def monotonic_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round(1)
      def events_of(type) = @events.select { |event| event.type == type }
      def presence(value) = (value.nil? || value.to_s.empty?) ? nil : value
      def cookie_name(raw) = raw.to_s.split("=", 2).first&.strip

      # The path component of a URL, or the URL unchanged if it cannot be parsed.
      def path_of(url)
        return nil unless url

        URI.parse(url).path
      rescue URI::InvalidURIError
        url
      end

      # Frames inside Dommy's own gems (and Capybara), skipped when locating the
      # test line that triggered an action. Tolerant of versioned gem dir names.
      INTERNAL_FRAMES = %r{/(dommy|dommy-rack|dommy-rails|capybara-dommy|capybara)[^/]*/lib/}

      def __internal_caller_source
        frame = caller_locations(2)&.find { |loc| !INTERNAL_FRAMES.match?(loc.path) }
        frame && "#{relative_path(frame.path)}:#{frame.lineno}"
      end

      def relative_path(path)
        root = "#{Dir.pwd}/"
        path.start_with?(root) ? path[root.length..] : path
      end
    end
  end
end

require_relative "trace/param_filter"
require_relative "trace/dom_observer"
require_relative "trace/formatter"
require_relative "trace/ndjson"
