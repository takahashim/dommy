# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "json"
require "dommy/rack"

module Dommy
  module Rails
    # The failure bundle (trace-roadmap.md phase 3): a failed example's trace
    # lands as a self-contained directory the standalone viewer opens.
    class TraceBundleTest < ::Minitest::Test
      def traced_session
        app = ->(_env) { [200, {"Content-Type" => "text/html"}, ["<html><body>hi</body></html>"]] }
        session = Dommy::Rack::Session.new(app, trace: true)
        session.visit "/x"
        session
      end

      def test_saves_a_bundle_named_after_the_example
        Dir.mktmpdir do |root|
          dir = TraceBundle.save_for_failure(
            traced_session.trace,
            id: "./spec/browser/posts_spec.rb[1:2]",
            description: "Posts creates a post",
            location: "./spec/browser/posts_spec.rb:12",
            root: root
          )
          assert_equal ::File.join(root, "spec-browser-posts_spec-rb-1-2"), dir
          lines = ::File.read(::File.join(dir, "trace.ndjson")).each_line.map { |l| JSON.parse(l) }
          assert_equal "failed", lines.last["status"]
          assert_equal "Posts creates a post", lines.first["metadata"]["example"]
        end
      end

      def test_never_raises
        assert_nil TraceBundle.save_for_failure(Object.new, id: "x")
      end
    end
  end
end
