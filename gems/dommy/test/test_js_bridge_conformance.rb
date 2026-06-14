# frozen_string_literal: true

require_relative "test_helper"
require "dommy/js/bridge_conformance"

# Runs the shared BridgeConformance suite Ruby-side: `round_trip` is just the
# Marshaller's wrap∘unwrap (no JS engine). This proves the suite is well-formed
# and the Ruby half of the wire protocol is self-consistent. The engine gems
# (dommy-js-quickjs, dommy-js-v8) include the SAME suite with a real
# JS round_trip, extending coverage across host_runtime.js.
class TestJsBridgeConformanceRubySide < Minitest::Test
  include Dommy::Js::BridgeConformance

  def setup
    @marshaller = Dommy::Js::Marshaller.new(Object.new)
  end

  # Ruby -> wire -> Ruby, without an engine.
  def round_trip(value)
    @marshaller.unwrap(@marshaller.wrap(value))
  end
end
