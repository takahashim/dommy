# frozen_string_literal: true

require "test_helper"
require "active_support/notifications"
require "dommy/rack"

module Dommy
  module Rails
    # Rails-internals spans (trace-roadmap.md phase 2): the subscriber turns
    # ActiveSupport::Notifications into completed spans on the in-flight
    # trace, so a traced request shows controller / SQL / render inside it.
    class TraceInstrumentationTest < ::Minitest::Test
      def app
        lambda do |_env|
          ::ActiveSupport::Notifications.instrument("process_action.action_controller",
            controller: "PostsController", action: "index", format: :html, status: 200) do
            ::ActiveSupport::Notifications.instrument("sql.active_record",
              name: "Post Load", sql: "SELECT * FROM posts") {}
            ::ActiveSupport::Notifications.instrument("sql.active_record",
              name: "SCHEMA", sql: "PRAGMA table_info") {}
            ::ActiveSupport::Notifications.instrument("render_template.action_view",
              identifier: "/app/app/views/posts/index.html.erb") {}
          end
          [200, {"Content-Type" => "text/html"}, ["<html><body>ok</body></html>"]]
        end
      end

      def test_notifications_become_spans_on_the_traced_request
        TraceInstrumentation.install!
        session = Dommy::Rack::Session.new(app, trace: true)
        session.visit "/posts"

        spans = session.trace.events.select { |e| e.type == :span }
        labels = spans.map { |s| [s.data[:kind], s.data[:label]] }
        assert_includes labels, %w[controller PostsController#index]
        assert_includes labels, ["db", "Post Load"]
        assert_includes labels, ["render", "template posts/index.html.erb"]
        # Housekeeping statements carry no app information.
        refute labels.any? { |_, label| label == "SCHEMA" }

        db = spans.find { |s| s.data[:kind] == "db" }
        assert_equal "SELECT * FROM posts", db.data[:sql]
        assert_operator db.data[:duration_ms], :>=, 0
      end

      def test_binds_mask_with_the_traces_own_filter
        TraceInstrumentation.install!(binds: true)
        custom = Dommy::Rack::Trace::ParamFilter::DEFAULT + ["ssn"]
        app = lambda do |_env|
          ::ActiveSupport::Notifications.instrument("sql.active_record",
            name: "User Load", sql: "SELECT 1",
            binds: [FakeBind.new("ssn")], type_casted_binds: ["123-45-6789"]) {}
          [200, {"Content-Type" => "text/html"}, ["<html><body>ok</body></html>"]]
        end
        session = Dommy::Rack::Session.new(app)
        trace = Dommy::Rack::Trace.attach(session, filter: custom)
        session.instance_variable_set(:@trace, trace)
        session.visit "/x"

        db = trace.events.find { |e| e.type == :span && e.data[:kind] == "db" }
        assert_equal({"ssn" => "[FILTERED]"}, db.data[:binds])
      end

      def test_install_is_idempotent
        TraceInstrumentation.install!
        assert_equal false, TraceInstrumentation.install!
      end

      FakeJob = Struct.new(:queue_name)
      FakeBind = Struct.new(:name)

      def wider_app
        lambda do |_env|
          ::ActiveSupport::Notifications.instrument("enqueue.active_job", job: FakeJob.new("mailers")) {}
          ::ActiveSupport::Notifications.instrument("deliver.action_mailer", mailer: "UserMailer") {}
          ::ActiveSupport::Notifications.instrument("sql.active_record",
            name: "User Load", sql: "SELECT * FROM users WHERE email = ? AND password = ?",
            binds: [FakeBind.new("email"), FakeBind.new("password")],
            type_casted_binds: ["a@example.com", "secret"]) {}
          [200, {"Content-Type" => "text/html"}, ["<html><body>ok</body></html>"]]
        end
      end

      def test_job_mail_and_opted_in_masked_binds
        TraceInstrumentation.install!(binds: true)
        session = Dommy::Rack::Session.new(wider_app, trace: true)
        session.visit "/x"

        spans = session.trace.events.select { |e| e.type == :span }
        labels = spans.map { |s| [s.data[:kind], s.data[:label]] }
        assert labels.any? { |kind, label| kind == "job" && label.end_with?("FakeJob") && label.start_with?("enqueue") }
        assert_includes labels, %w[mail UserMailer]

        db = spans.find { |s| s.data[:kind] == "db" }
        assert_equal({"email" => "a@example.com", "password" => "[FILTERED]"}, db.data[:binds])
      end

      # Subscriptions install once, so `binds:` is the only knob there is —
      # it has to work in BOTH directions or a suite that opted in once can
      # never opt back out.
      def test_binds_can_be_turned_back_off_after_being_enabled
        TraceInstrumentation.install!(binds: true)
        TraceInstrumentation.install!(binds: false)
        session = Dommy::Rack::Session.new(wider_app, trace: true)
        session.visit "/x"

        db = session.trace.events.find { |e| e.type == :span && e.data[:kind] == "db" }
        assert_nil db.data[:binds]
      end

      # Some adapters publish type_casted_binds as a callable that defers the
      # casting until a subscriber reads it (ActiveRecord::LogSubscriber
      # unwraps exactly this). Taken literally, a one-bind statement would
      # record the Proc itself and anything longer would drop its binds.
      def test_a_deferred_type_casted_binds_callable_is_unwrapped
        TraceInstrumentation.install!(binds: true)
        app = lambda do |_env|
          ::ActiveSupport::Notifications.instrument("sql.active_record",
            name: "User Load", sql: "SELECT 1",
            binds: [FakeBind.new("email")],
            type_casted_binds: -> { ["a@example.com"] }) {}
          [200, {"Content-Type" => "text/html"}, ["<html><body>ok</body></html>"]]
        end
        session = Dommy::Rack::Session.new(app, trace: true)
        session.visit "/x"

        db = session.trace.events.find { |e| e.type == :span && e.data[:kind] == "db" }
        assert_equal({"email" => "a@example.com"}, db.data[:binds])
      end
    end
  end
end
