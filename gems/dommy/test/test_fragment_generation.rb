# frozen_string_literal: true

require "test_helper"

# `Parser.fragment_generation` is the guard NodeWrapperCache#wrap uses to skip
# its per-hit liveness validation: while no fragment has been parsed since a
# cache was born, no transient backend node can exist, so no freed identity can
# have been recycled under a cached wrapper. The guard is only as good as the
# invariant it counts — EVERY fragment parse has to go through Parser.fragment.
# A single `backend_doc.fragment(...)` slipping back into lib/ silently
# reintroduces the bug the validation was added for (a Fragment clone resolving
# to a cached TextNode), and no functional test would catch it.
class TestFragmentGenerationDriftGuard < Minitest::Test
  LIB_ROOT = File.expand_path("../lib", __dir__)

  # The one file allowed to call the backend's fragment builders: Parser itself,
  # which is where the counter is bumped.
  ALLOWED = ["dommy/parser.rb", "dommy/backend.rb"].freeze

  def test_every_fragment_parse_in_lib_goes_through_parser
    offenders = Dir.glob(File.join(LIB_ROOT, "**", "*.rb")).filter_map do |path|
      relative = path.delete_prefix("#{LIB_ROOT}/")
      next if ALLOWED.include?(relative)

      hits = File.readlines(path).each_with_index.select do |line, _i|
        # `something.fragment(...)` that isn't `Parser.fragment(...)`, ignoring
        # comment lines.
        line !~ /^\s*#/ && line =~ /\.fragment\(/ && line !~ /Parser\.fragment\(/
      end
      next if hits.empty?

      "#{relative}:#{hits.map { |_l, i| i + 1 }.join(",")}"
    end

    assert_empty offenders,
      "these call the backend's fragment builder directly; route them through " \
      "Parser.fragment so the fragment generation counts them"
  end

  def test_parser_fragment_moves_the_generation_for_both_paths
    before = Dommy::Parser.fragment_generation
    Dommy::Parser.fragment("<p>x</p>")
    assert_equal before + 1, Dommy::Parser.fragment_generation

    doc = Dommy.parse("<html><body></body></html>")
    backend = (doc.respond_to?(:document) ? doc.document : doc).backend_doc
    Dommy::Parser.fragment("<p>y</p>", owner_doc: backend)
    assert_operator Dommy::Parser.fragment_generation, :>, before + 1
  end

  # The cache's fast path is only sound while the counter it captured still
  # matches; a fragment parse anywhere has to put it back on the validating path.
  def test_a_fragment_parse_reopens_the_liveness_validation
    doc = Dommy.parse("<html><body><p>hi</p></body></html>")
    doc = doc.document if doc.respond_to?(:document)
    cache = doc.instance_variable_get(:@wrapper_cache) ||
      doc.instance_variable_get(:@node_wrapper_cache)
    skip "the wrapper cache is not reachable from Document" unless cache

    captured = cache.instance_variable_get(:@initial_fragment_generation)
    assert_equal captured, Dommy::Parser.fragment_generation

    Dommy::Parser.fragment("<span>transient</span>")
    refute_equal captured, Dommy::Parser.fragment_generation
  end
end
