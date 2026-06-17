# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"

module Dommy
  module Rack
    # DOM snapshot artifacts: captured on document load when `trace_snapshots:`,
    # held out of the timeline, embedded inline by #to_ndjson or externalized to
    # files by #save.
    class TraceSnapshotsTest < Minitest::Test
      include RackTestHelper

      HTML = "<html><head><title>Hi</title></head><body><h1>こんにちは</h1></body></html>"

      def visited_trace
        session = Session.new(app_for("GET /hello" => html_response(HTML)),
          trace: true, trace_snapshots: true)
        session.visit "/hello"
        session.trace
      end

      def parse(ndjson) = ndjson.each_line.map { |line| JSON.parse(line) }

      def test_captures_a_dom_snapshot_artifact
        trace = visited_trace

        artifact = trace.events.find { |event| event.type == :artifact }
        refute_nil artifact
        assert_equal "dom_snapshot", artifact.data[:kind]

        html = trace.artifacts[artifact.seq]
        assert_includes html, "こんにちは" # the captured DOM HTML, kept out of the event
      end

      def test_no_snapshot_without_the_option
        session = Session.new(app_for("GET /x" => html_response(HTML)), trace: true)
        session.visit "/x"
        assert_empty session.trace.events.select { |event| event.type == :artifact }
      end

      def test_to_ndjson_embeds_artifact_content_inline
        lines = parse(visited_trace.to_ndjson)
        artifact = lines.find { |line| line["op"] == "artifact_ref" }

        refute_nil artifact
        assert_equal "dom_snapshot", artifact["kind"]
        assert_includes artifact["content"], "こんにちは"
        refute artifact.key?("path")
      end

      def test_save_externalizes_artifacts_to_files
        Dir.mktmpdir do |dir|
          visited_trace.save(dir, status: "failed")

          ndjson = ::File.read(::File.join(dir, "trace.ndjson"))
          assert_equal "failed", parse(ndjson).last["status"]

          artifact = parse(ndjson).find { |line| line["op"] == "artifact_ref" }
          assert_equal "artifacts/art_#{artifact["seq"]}.html", artifact["path"]
          refute artifact.key?("content") # externalized, not inline

          saved = ::File.read(::File.join(dir, artifact["path"]))
          assert_includes saved, "こんにちは"
        end
      end
    end
  end
end
