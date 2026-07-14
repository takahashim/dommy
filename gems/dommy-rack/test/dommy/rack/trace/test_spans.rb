# frozen_string_literal: true

require "test_helper"
require "json"

module Dommy
  module Rack
    # Inside-the-request spans (trace-roadmap.md phase 2): an instrumentation
    # layer reaches the in-flight trace via the thread-local and buffers
    # completed spans; they flush after the enclosing :http event, parented
    # to it, as flat v2 `span` lines.
    class TraceSpansTest < Minitest::Test
      include RackTestHelper

      def instrumented_app
        app_for("GET /x" => lambda do |_req|
          trace = Thread.current[:__dommy_active_trace__]
          trace&.__internal_record_span__(kind: :controller, label: "PostsController#index",
            duration_ms: 5.678, data: {status: 200})
          trace&.__internal_record_span__(kind: :db, label: "Post Load",
            duration_ms: 1.234, data: {sql: "SELECT * FROM posts"})
          html_response("<html><body>ok</body></html>")
        end)
      end

      def test_spans_flush_after_their_http_event_with_parent
        session = Session.new(instrumented_app, trace: true)
        session.visit "/x"
        events = session.trace.events

        http = events.find { |e| e.type == :http }
        spans = events.select { |e| e.type == :span }
        assert_equal %w[PostsController#index], [spans[0].data[:label]]
        assert_equal "Post Load", spans[1].data[:label]
        spans.each do |span|
          assert_operator span.seq, :>, http.seq
          assert_equal http.seq, span.data[:parent]
        end
        assert_nil Thread.current[:__dommy_active_trace__]
      end

      def test_spans_serialize_as_flat_v2_lines_and_render_in_text
        session = Session.new(instrumented_app, trace: true)
        session.visit "/x"

        lines = session.trace.to_ndjson(status: "ok").each_line.map { |l| JSON.parse(l) }
        span = lines.find { |l| l["op"] == "span" && l["kind"] == "db" }
        assert_equal "Post Load", span["label"]
        assert_equal 1.23, span["duration_ms"]
        assert_equal "SELECT * FROM posts", span["sql"]
        assert_kind_of Integer, span["parent"]

        assert_includes session.trace.to_text, "SPAN [db] Post Load (1.23ms)"
      end

      def test_an_aborted_request_closes_the_bracket_and_keeps_its_spans
        app = app_for("GET /boom" => lambda do |_req|
          trace = Thread.current[:__dommy_active_trace__]
          trace&.__internal_record_span__(kind: :db, label: "Doomed Load", duration_ms: 0.5)
          raise "kaboom"
        end)
        session = Session.new(app, trace: true)
        assert_raises(RuntimeError) { session.visit "/boom" }

        # The bracket closed: nothing leaks to later notifications.
        assert_nil Thread.current[:__dommy_active_trace__]

        events = session.trace.events
        http = events.find { |e| e.type == :http }
        assert_equal true, http.data[:aborted]
        assert_nil http.data[:status]
        span = events.find { |e| e.type == :span }
        assert_equal "Doomed Load", span.data[:label]
        assert_equal http.seq, span.data[:parent]
      end

      def test_spans_are_dropped_without_an_open_request
        session = Session.new(instrumented_app, trace: true)
        session.trace.__internal_record_span__(kind: :db, label: "stray", duration_ms: 1)
        session.visit "/x"
        refute session.trace.events.any? { |e| e.type == :span && e.data[:label] == "stray" }
      end
    end
  end
end
