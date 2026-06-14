# frozen_string_literal: true

module Dommy
  module Js
    # A shared, engine-agnostic conformance suite for the Ruby<->JS wire
    # protocol. It is shipped from core (next to host_runtime.js and the
    # Marshaller it validates) but RUN by each engine gem (dommy-js-quickjs,
    # dommy-js-v8, …) against its own runtime — that is how the .js half and the
    # Ruby half are kept in sync across every backend.
    #
    # Usage from an engine gem's test suite:
    #
    #   require "dommy/js/bridge_conformance"
    #
    #   class V8BridgeConformanceTest < Minitest::Test
    #     include Dommy::Js::BridgeConformance
    #     def round_trip(value)
    #       # Send `value` Ruby -> JS and bring it back. Typically: wrap it, pass
    #       # it through a JS identity function via the bridge, and unwrap the
    #       # result. The engine gem knows the mechanics for its runtime.
    #     end
    #   end
    #
    # Core itself includes the suite with a Marshaller-only `round_trip` (no
    # engine) to verify the Ruby half is self-consistent and the suite is
    # well-formed; the engine gems extend the same assertions across the real JS
    # boundary (host_runtime.js dehydrate/rehydrate). The assert_* helpers come
    # from the including Minitest::Test, so this module pulls in no test
    # framework of its own.
    #
    # Includers must define:
    #   round_trip(ruby_value) -> the value after Ruby -> JS -> Ruby
    # and may override:
    #   conformance_bridgeable_object -> a fresh bridge-able Ruby object
    module BridgeConformance
      # A minimal bridge-able object (implements the object ABI), so the handle /
      # identity round-trip has something to carry. Engine gems may override to
      # use a real DOM node.
      def conformance_bridgeable_object
        object = Object.new
        def object.__js_get__(key) = key
        object
      end

      def test_conformance_round_trips_scalars
        assert_equal "hello", round_trip("hello")
        assert_equal 42, round_trip(42)
        assert_in_delta 1.5, round_trip(1.5)
        assert_equal true, round_trip(true)
        assert_equal false, round_trip(false)
        assert_nil round_trip(nil)
      end

      # JS `undefined` must survive as the dedicated sentinel, distinct from null.
      def test_conformance_round_trips_undefined
        assert_same Dommy::Bridge::UNDEFINED, round_trip(Dommy::Bridge::UNDEFINED)
      end

      def test_conformance_round_trips_nested_structures
        value = {"a" => [1, "two", {"b" => true, "c" => nil}]}
        assert_equal value, round_trip(value)
      end

      # A byte buffer must come back as a byte buffer with the same bytes (it
      # crosses as a typed array on the JS side).
      def test_conformance_round_trips_bytes
        result = round_trip(Dommy::Bridge::Bytes.new([1, 2, 3, 255]))
        assert_respond_to result, :to_a
        assert_equal [1, 2, 3, 255], result.to_a
      end

      # A bridge-able Ruby object crosses as a proxy and returns as the SAME Ruby
      # object (stable cross-boundary identity via the handle table).
      def test_conformance_preserves_object_identity
        object = conformance_bridgeable_object
        assert_same object, round_trip(object)
      end
    end
  end
end
