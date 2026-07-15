# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require "tempfile"

module Dommy
  module Rack
    # Live streaming (trace-roadmap.md phase 4): each event lands as an
    # NDJSON line the moment it is recorded, so a tailing viewer follows the
    # run and a killed process still leaves the prefix.
    class TraceStreamTest < Minitest::Test
      include RackTestHelper

      def app
        app_for("GET /x" => html_response("<html><head><title>X</title></head><body>hi</body></html>"))
      end

      def test_streams_each_event_as_it_happens_and_brackets_on_finish
        io = StringIO.new
        session = Session.new(app, trace: true)
        session.trace.stream_to(io, metadata: {"example" => "live"})

        session.visit "/x"
        mid = io.string.each_line.map { |l| JSON.parse(l) }
        assert_equal "trace_start", mid.first["op"]
        assert_equal "live", mid.first["metadata"]["example"]
        assert_includes mid.map { |l| l["op"] }, "http"
        refute_includes mid.map { |l| l["op"] }, "trace_end"

        session.trace.finish_stream(status: "ok")
        lines = io.string.each_line.map { |l| JSON.parse(l) }
        assert_equal "trace_end", lines.last["op"]
        assert_equal "ok", lines.last["status"]
        # The streamed document folds exactly like the batch one.
        assert_equal session.trace.to_ndjson(status: "ok").each_line.count, lines.count
      end

      def test_streamed_snapshot_artifacts_carry_their_content
        io = StringIO.new
        session = Session.new(app, trace: true, trace_snapshots: true)
        session.trace.stream_to(io)
        session.visit "/x"
        session.trace.finish_stream(status: "ok")

        lines = io.string.each_line.map { |l| JSON.parse(l) }
        artifact = lines.find { |l| l["op"] == "artifact_ref" }
        assert_includes artifact["content"], "<title>X</title>"
        # And the streamed document still folds exactly like the batch one
        # (modulo the trace_end wall clock, stamped at generation time).
        strip = ->(l) { l.reject { |k, _| k == "wall_ms" } }
        assert_equal session.trace.to_ndjson(status: "ok").each_line.map { |l| strip.call(JSON.parse(l)) },
          lines.map { |l| strip.call(l) }
      end

      def test_streams_to_a_path_and_survives_a_dead_io
        Tempfile.create(["live", ".trace.ndjson"]) do |f|
          session = Session.new(app, trace: true)
          session.trace.stream_to(f.path)
          session.visit "/x"
          session.trace.finish_stream(status: "failed")
          lines = ::File.read(f.path).each_line.map { |l| JSON.parse(l) }
          assert_equal %w[trace_start trace_end], [lines.first["op"], lines.last["op"]]
        end

        # dispose brackets an un-finished stream (contract: ends in trace_end).
        Tempfile.create(["disp", ".trace.ndjson"]) do |f|
          session = Session.new(app, trace: true)
          session.trace.stream_to(f.path)
          session.visit "/x"
          assert session.trace.streaming?
          session.dispose # caller never called finish_stream
          refute session.trace.streaming?
          lines = ::File.read(f.path).each_line.map { |l| JSON.parse(l) }
          assert_equal "trace_end", lines.last["op"]
          assert_equal "cancelled", lines.last["status"]
        end

        # Re-opening a stream closes the prior owned file (no fd leak) instead
        # of dropping it silently.
        Tempfile.create(["a", ".ndjson"]) do |a|
          Tempfile.create(["b", ".ndjson"]) do |b|
            session = Session.new(app, trace: true)
            session.trace.stream_to(a.path)
            session.trace.stream_to(b.path) # supersedes a
            session.visit "/x"
            session.trace.finish_stream(status: "ok")
            assert_equal "trace_end", ::File.read(b.path).each_line.map { |l| JSON.parse(l) }.last["op"]
          end
        end

        # A sink that dies mid-run: the trace drops the stream and carries on.
        dead = Object.new
        def dead.write(*)
          @writes = (@writes || 0) + 1
          raise IOError if @writes > 1
        end
        session = Session.new(app, trace: true)
        session.trace.stream_to(dead)
        session.visit "/x" # must not raise
        assert session.trace.events.any? { |e| e.type == :http }
      end
    end
  end
end
