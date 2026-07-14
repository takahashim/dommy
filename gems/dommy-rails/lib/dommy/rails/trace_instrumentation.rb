# frozen_string_literal: true

module Dommy
  module Rails
    # Fills the inside of a traced request: subscribes to the Rails
    # ActiveSupport::Notifications topics (controller action, SQL, template /
    # partial rendering, job enqueue/perform, mail delivery) and buffers each
    # finished event as a completed span on the trace whose request is in
    # flight — Dommy calls the app synchronously, so
    # `Thread.current[:__dommy_active_trace__]` (set by Dommy::Rack::Trace
    # around the Rack call) IS the request's trace.
    #
    # Installed automatically when a BrowserSpec test boots its browser;
    # callable directly (idempotent) from a suite hook too:
    #
    #   Dommy::Rails::TraceInstrumentation.install!
    #   Dommy::Rails::TraceInstrumentation.install!(binds: true)
    #
    # SQL bind values are excluded by default; `binds: true` includes them as
    # {name => value}, masked through the same sensitive-key filter the trace
    # applies to form params (password/token/… become [FILTERED]).
    module TraceInstrumentation
      TOPICS = {
        "process_action.action_controller" => :controller,
        "sql.active_record" => :db,
        "render_template.action_view" => :render,
        "render_partial.action_view" => :render,
        "enqueue.active_job" => :job,
        "perform.active_job" => :job,
        "deliver.action_mailer" => :mail,
      }.freeze

      # Statement names carrying no application information.
      SKIPPED_SQL_NAMES = ["SCHEMA", "TRANSACTION"].freeze

      module_function

      def install!(binds: false)
        @include_binds = binds if binds
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
        when :db then db_span(payload)
        when :render
          identifier = payload[:identifier].to_s
          # The app-relative template path reads better than the absolute one.
          label = identifier.sub(%r{\A.*/app/views/}, "")
          {label: "#{topic.start_with?("render_partial") ? "partial" : "template"} #{label}",
           data: nil}
        when :job
          job = payload[:job]
          {label: "#{topic.start_with?("enqueue") ? "enqueue" : "perform"} #{job.class.name}",
           data: ({queue: job.queue_name.to_s} if job.respond_to?(:queue_name))}
        when :mail
          {label: payload[:mailer].to_s, data: nil}
        end
      end

      def db_span(payload)
        name = payload[:name].to_s
        return nil if SKIPPED_SQL_NAMES.include?(name)

        data = {sql: payload[:sql].to_s}
        if @include_binds && (masked = masked_binds(payload))
          data[:binds] = masked
        end
        {label: name.empty? ? "SQL" : name, data: data}
      end

      # {attribute name => type-cast value}, sensitive keys masked with the
      # in-flight trace's OWN filter (so custom filter keys apply to binds
      # exactly as to form params), falling back to the shared default. nil
      # when the payload carries no usable binds.
      def masked_binds(payload)
        names = Array(payload[:binds]).map { |b| b.respond_to?(:name) ? b.name.to_s : b.to_s }
        values = Array(payload[:type_casted_binds])
        return nil if names.empty? || names.length != values.length

        bind_filter.form_params(names.zip(values))
      end

      def bind_filter
        trace = Thread.current[:__dommy_active_trace__]
        return trace.__internal_param_filter__ if trace.respond_to?(:__internal_param_filter__)

        @default_filter ||= Dommy::Rack::Trace::ParamFilter.new(Dommy::Rack::Trace::ParamFilter::DEFAULT)
      end
    end
  end
end
