# frozen_string_literal: true

require "test_helper"
require "json"
require "support/trace_contract"

module Dommy
  module Rack
    # The NDJSON contract with the standalone viewer (dommylizer): the same
    # fixture file is committed in BOTH repos, produced here and parsed there.
    # If this test fails after an intentional format change, regenerate the
    # fixture (see TraceContract) and copy it to the viewer's repo too.
    class TraceContractTest < Minitest::Test
      def test_emitter_output_matches_the_committed_contract_fixture
        expected = TraceContract.normalize(::File.read(TraceContract::FIXTURE))
        actual = TraceContract.normalize(TraceContract.generate)
        assert_equal expected, actual
      end

      def test_fixture_carries_the_contract_surface
        lines = TraceContract.normalize(::File.read(TraceContract::FIXTURE))
        assert_equal "trace_start", lines.first["op"]
        assert_equal 2, lines.first["version"]
        assert_equal "trace_end", lines.last["op"]
        ops = lines.map { |l| l["op"] }
        %w[action http document form error].each { |op| assert_includes ops, op }
      end
    end
  end
end
