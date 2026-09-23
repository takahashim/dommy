# frozen_string_literal: true

module Dommy
  module Js
    # Registry of JS runtime backends, keyed by name. A backend gem registers a
    # factory on load (e.g. dommy-js-quickjs registers :quickjs); the host layer
    # builds runtimes through `build_runtime` instead of naming a concrete class.
    @runtime_factories = {}
    @default_runtime = nil

    class << self
      # The name of the backend `build_runtime` uses when none is given. Set by
      # the first backend to register (and overridable by the host).
      attr_accessor :default_runtime

      # Register a runtime factory under `name`. The factory receives the keyword
      # options passed to `build_runtime` and must return an object satisfying
      # the Runtime contract. The first registration becomes the default.
      def register_runtime(name, &factory)
        raise ArgumentError, "a factory block is required" unless factory

        @runtime_factories[name.to_sym] = factory
        @default_runtime ||= name.to_sym
        name.to_sym
      end

      def runtime_registered?(name) = @runtime_factories.key?(name.to_sym)

      def registered_runtimes = @runtime_factories.keys

      # Build a runtime from the named backend (or the default), passing `opts`
      # to its factory. Verifies the result conforms before handing it back.
      def build_runtime(name = nil, **opts)
        name = (name || @default_runtime)&.to_sym
        factory = @runtime_factories[name]
        unless factory
          raise ArgumentError,
            "unknown JS runtime backend #{name.inspect} " \
            "(registered: #{registered_runtimes.inspect})"
        end

        Runtime.assert_conformance!(factory.call(**opts))
      end
    end
  end
end
