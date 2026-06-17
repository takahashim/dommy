# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"

module Dommy
  module Rack
    # NDJSON v2 output: the on-disk contract the standalone trace viewer reads.
    class TraceNdjsonTest < Minitest::Test
      include RackTestHelper

      def trace_for_visit
        app = app_for("GET /hello" => html_response(
          "<html><head><title>Hi</title></head><body><h1>Hello</h1></body></html>"
        ))
        session = Session.new(app, trace: true)
        session.visit "/hello"
        session.trace
      end

      def parse(ndjson) = ndjson.each_line.map { |line| JSON.parse(line) }

      def test_brackets_events_with_trace_start_and_end
        lines = parse(trace_for_visit.to_ndjson(status: "failed"))

        assert_equal "trace_start", lines.first["op"]
        assert_equal 2, lines.first["version"]
        assert_equal "verbose", lines.first["level"]

        assert_equal "trace_end", lines.last["op"]
        assert_equal "failed", lines.last["status"]
      end

      def test_maps_event_types_to_ops_with_fields
        lines = parse(trace_for_visit.to_ndjson)
        ops = lines.map { |line| line["op"] }
        assert_includes ops, "action"
        assert_includes ops, "http"
        assert_includes ops, "document"

        http = lines.find { |line| line["op"] == "http" }
        assert_equal "GET", http["method"]
        assert_equal "/hello", http["path"]
        assert_equal 200, http["status"]
        assert http.key?("seq")

        action = lines.find { |line| line["op"] == "action" }
        assert_equal "visit", action["verb"]
        assert_equal "/hello", action["label"]
      end

      def test_non_action_events_reference_their_action
        lines = parse(trace_for_visit.to_ndjson)
        action_seq = lines.find { |line| line["op"] == "action" }["seq"]
        http = lines.find { |line| line["op"] == "http" }
        assert_equal action_seq, http["action"]
      end

      def test_lines_carry_monotonic_wall_ms
        lines = parse(trace_for_visit.to_ndjson)
        walls = lines.map { |line| line["wall_ms"] }
        assert(walls.all? { |w| w.is_a?(Numeric) })  # every line timed
        assert_equal walls, walls.sort                # non-decreasing (real elapsed)
        assert_equal 0.0, lines.first["wall_ms"]      # trace_start at zero
      end

      def test_action_carries_the_caller_source
        lines = parse(trace_for_visit.to_ndjson)
        action = lines.find { |line| line["op"] == "action" }
        # The first non-Dommy frame is this test file (where #visit was called).
        assert_match %r{test/dommy/rack/trace/test_ndjson\.rb:\d+\z}, action["source"]
      end

      def test_record_error_appends_a_linked_error_event
        trace = trace_for_visit
        trace.record_error(message: "expected to find text \"Created\"",
          exception_class: "RSpec::Expectations::ExpectationNotMetError")
        lines = parse(trace.to_ndjson(status: "failed"))

        error = lines.find { |line| line["op"] == "error" }
        refute_nil error
        assert_equal "Expectation failed", error["label"]
        assert_equal "expected to find text \"Created\"", error["data"]["message"]
        assert error["action"] # linked to the open action (the visit)
      end

      def test_each_line_is_standalone_compact_json
        ndjson = trace_for_visit.to_ndjson
        ndjson.each_line { |line| JSON.parse(line) } # no raise
        refute_includes ndjson, "\n\n"                # no blank lines (spec §3)
        refute_includes ndjson, "  "                  # compact, not pretty
        assert ndjson.end_with?("\n")
      end

      def test_write_ndjson_to_a_file
        Dir.mktmpdir do |dir|
          path = ::File.join(dir, "run.trace.ndjson")
          trace_for_visit.write_ndjson(path, status: "ok")
          assert_equal "trace_start", JSON.parse(::File.read(path).lines.first)["op"]
        end
      end

      # --- mapping units (no DOM/JS engine needed) ---

      def test_dom_event_renames_inner_op_to_kind
        event = Trace::Event.new(seq: 5, t: 1.0, type: :dom, name: nil, action_seq: 2,
          data: {op: :added, target: "div#x", count: 3})
        line = Trace::Ndjson.event_line(event)

        assert_equal "dom", line[:op]       # top-level op stays "dom"
        assert_equal :added, line[:kind]    # mutation kind moved to :kind
        assert_equal 3, line[:count]
        assert_equal 2, line[:action]
      end

      def test_action_event_exposes_verb_and_label
        event = Trace::Event.new(seq: 1, t: nil, type: :action, name: :click_button,
          action_seq: nil, data: {verb: :click_button, label: "Save"})
        line = Trace::Ndjson.event_line(event)

        assert_equal "action", line[:op]
        assert_equal :click_button, line[:verb]
        assert_equal "Save", line[:label]
        refute line.key?(:action) # an action is not nested under another action
      end
    end
  end
end
