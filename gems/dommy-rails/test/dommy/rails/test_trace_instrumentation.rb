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

      def test_install_is_idempotent
        TraceInstrumentation.install!
        assert_equal false, TraceInstrumentation.install!
      end
    end
  end
end
