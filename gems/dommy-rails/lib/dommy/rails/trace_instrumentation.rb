# frozen_string_literal: true

module Dommy
  module Rails
    # Fills the inside of a traced request: subscribes to the Rails
    # ActiveSupport::Notifications topics (controller action, SQL, template /
    # partial rendering) and buffers each finished event as a completed span
    # on the trace whose request is in flight — Dommy calls the app
    # synchronously, so `Thread.current[:__dommy_active_trace__]` (set by
    # Dommy::Rack::Trace around the Rack call) IS the request's trace.
    #
    # Install once (idempotent) from a test-suite hook:
    #
    #   Dommy::Rails::TraceInstrumentation.install!
    #
    # SQL bind values never enter the trace (only the parameterized statement
    # text and the statement name), so nothing sensitive leaks even before
    # redaction rules are configured.
    module TraceInstrumentation
      TOPICS = {
        "process_action.action_controller" => :controller,
        "sql.active_record" => :db,
        "render_template.action_view" => :render,
        "render_partial.action_view" => :render,
      }.freeze

      # Statement names carrying no application information.
      SKIPPED_SQL_NAMES = ["SCHEMA", "TRANSACTION"].freeze

      module_function

      def install!
        return false if @installed
        return false unless defined?(::ActiveSupport::Notifications)

        TOPICS.each do |topic, kind|
          ::ActiveSupport::Notifications.monotonic_subscribe(topic) do |_name, started, finished, _id, payload|
            record(kind, topic, (finished - started) * 1000.0, payload)
          end
        end
        @installed = true
      end

      def record(kind, topic, duration_ms, payload)
        trace = Thread.current[:__dommy_active_trace__]
        return unless trace.respond_to?(:__internal_record_span__)

        span = build_span(kind, topic, payload)
        return unless span

        trace.__internal_record_span__(kind: kind, label: span[:label],
          duration_ms: duration_ms, data: span[:data])
      rescue StandardError
        nil # instrumentation must never break the request
      end

      def build_span(kind, topic, payload)
        case kind
        when :controller
          {label: "#{payload[:controller]}##{payload[:action]}",
           data: {format: payload[:format].to_s, status: payload[:status]}.compact}
        when :db
          name = payload[:name].to_s
          return nil if SKIPPED_SQL_NAMES.include?(name)

          {label: name.empty? ? "SQL" : name, data: {sql: payload[:sql].to_s}}
        when :render
          identifier = payload[:identifier].to_s
          # The app-relative template path reads better than the absolute one.
          label = identifier.sub(%r{\A.*/app/views/}, "")
          {label: "#{topic.start_with?("render_partial") ? "partial" : "template"} #{label}",
           data: nil}
        end
      end
    end
  end
end
