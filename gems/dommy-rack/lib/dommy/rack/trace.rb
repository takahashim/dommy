# frozen_string_literal: true

require "json"
require "uri"

module Dommy
  module Rack
    # A structured, virtual-time-ordered record of what a Session did: user
    # actions, HTTP exchanges (each redirect hop included), document loads,
    # script boots, console output, JS errors, and — opt-in — DOM mutations.
    # One ordered event stream, not a log: it powers readable failure reports
    # and machine-readable diagnostics (`to_text` / `to_json`).
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
      Event = Struct.new(:seq, :t, :type, :name, :action_seq, :data, keyword_init: true)

      # Recording verbosity. `:off` records nothing; `:actions` records the
      # action / http / form / document / dom timeline; `:verbose` adds the
      # JS-realm streams (script / console / js_error).
      LEVELS = %i[off actions verbose].freeze
      REALM_TYPES = %i[script console js_error].freeze

      # Parameter names matching any of these are masked in `:form` data so a
      # password / token never lands in a trace artifact. Override via
      # `filter:` (dommy-rails passes Rails' filter_parameters).
      DEFAULT_FILTER = [/pass/i, /secret/i, /token/i, /api[-_]?key/i, /auth/i, /csrf/i].freeze
      FILTERED = "[FILTERED]"

      # Build a Trace, wire it to the session's (and its runtime's) seams, and
      # return it. A `:off` trace wires nothing.
      def self.attach(session, level: :verbose, dom: false, filter: DEFAULT_FILTER)
        trace = new(session, level: level, dom: dom, filter: filter)
        trace.__internal_wire
        trace
      end

      attr_reader :events, :level

      def initialize(session, level: :verbose, dom: false, filter: DEFAULT_FILTER)
        @session = session
        @level = LEVELS.include?(level) ? level : :verbose
        @dom = dom
        @filter = filter
        @events = []
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
        @events << Event.new(seq: @seq, t: now_ms, type: :action, name: verb, action_seq: nil,
          data: {verb: verb, label: label})
        nil
      end

      # Record a form submission (method, path, filtered params). Form params
      # arrive as ordered [name, value] pairs; present them as a masked hash.
      def __internal_record_form(method:, url:, params: nil)
        __internal_emit(:form, {method: method, path: path_of(url) || url, params: form_params(params)})
      end

      # Drain the current window's microtasks so queued MutationObserver records
      # are delivered (JS mode does this via after_interaction; non-JS / tests
      # call this explicitly).
      def flush_dom
        return unless @dom

        current_window&.scheduler&.drain_microtasks
        nil
      end

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
      def to_h = {version: "1", events: @events.map { |e| Formatter.event_hash(e) }}
      def to_json(*_args) = ::JSON.pretty_generate(to_h)
      def to_s = to_text

      private

      # Emit one event, gated by the recording level. `seq` is the canonical
      # order; `t` is the virtual clock if a window exists.
      def __internal_emit(type, data, name: nil, window: nil)
        return if @level == :off
        return if REALM_TYPES.include?(type) && @level != :verbose

        @seq += 1
        @events << Event.new(seq: @seq, t: window&.scheduler&.now_ms, type: type, name: name,
          action_seq: @action_seq, data: data)
        nil
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
        nil
      end

      def __internal_on_response(response)
        request = @pending_request || {}
        @pending_request = nil
        __internal_emit(:http, {
          method: request[:method],
          path: request[:path] || path_of(response.url),
          query: request[:query],
          status: response.status,
          content_type: response.content_type,
          location: response.location_header,
          set_cookie: response.set_cookie_strings.map { |raw| cookie_name(raw) }
        })
      end

      def __internal_on_document(window)
        __internal_emit(:document, {url: @session.current_url, title: window&.document&.title}, window: window)
        __internal_setup_dom_observer(window) if @dom
      end

      # --- DOM observation (Phase 2; inert unless dom: true) ---

      def __internal_setup_dom_observer(window)
        body = window&.document&.body
        return unless body

        observer = Dommy::MutationObserver.new(window, method(:__internal_on_mutations))
        # `observe` is the observer's JS-bridge entry point (Ruby-private), so
        # drive it through the public bridge call.
        observer.__js_call__("observe", [body, {childList: true, subtree: true, attributes: true, characterData: true}])
        @observers << observer
        nil
      end

      def __internal_on_mutations(records, _observer)
        window = current_window
        records.each do |record|
          summary = mutation_summary(record)
          next unless summary

          __internal_emit_dom(summary, window)
        end
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

      def mutation_summary(record)
        case record.type
        when "childList"
          if node_count(record.added_nodes).positive?
            {op: :added, target: node_label(record.target), count: node_count(record.added_nodes)}
          elsif node_count(record.removed_nodes).positive?
            {op: :removed, target: node_label(record.target), count: node_count(record.removed_nodes)}
          end
        when "attributes"
          {op: :attr, target: node_label(record.target), attr: record.attribute_name}
        when "characterData"
          {op: :text, target: node_label(record.target)}
        end
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

      # Turn ordered [name, value] form pairs into a masked hash. A non-pairs
      # shape (already a hash / scalar) falls through to recursive masking.
      def form_params(params)
        return filter_params(params) unless params.is_a?(Array) && params.all? { |p| p.is_a?(Array) && p.size == 2 }

        params.each_with_object({}) do |(name, value), out|
          out[name] = filtered_key?(name) ? FILTERED : value
        end
      end

      # Recursively mask sensitive parameter values by key name.
      def filter_params(params)
        case params
        when Hash
          params.each_with_object({}) do |(key, value), out|
            out[key] = filtered_key?(key) ? FILTERED : filter_params(value)
          end
        when Array
          params.map { |value| filter_params(value) }
        else
          params
        end
      end

      def filtered_key?(key)
        name = key.to_s
        @filter.any? { |matcher| matcher.is_a?(Regexp) ? matcher.match?(name) : name == matcher.to_s }
      end

      def node_label(node)
        return node.to_s unless node.respond_to?(:tag_name) && node.tag_name

        label = node.tag_name.downcase
        id = node.respond_to?(:get_attribute) ? node.get_attribute("id") : nil
        label += "##{id}" if presence(id)
        klass = node.respond_to?(:get_attribute) ? node.get_attribute("class") : nil
        label += ".#{klass.split.join(".")}" if presence(klass)
        label
      end

      def node_count(list)
        return 0 if list.nil?
        return list.length if list.respond_to?(:length)
        return list.size if list.respond_to?(:size)

        0
      end

      def current_window = @session.document&.default_view
      def now_ms = current_window&.scheduler&.now_ms
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
    end
  end
end

require_relative "trace/formatter"
