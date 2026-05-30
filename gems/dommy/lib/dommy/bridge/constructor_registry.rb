# frozen_string_literal: true

module Dommy
  module Bridge
    # Maps JS global constructor names (e.g. "Event", "URL", "XMLHttpRequest")
    # to their `Bridge::Constructor` instances. Window builds one and routes
    # `__js_get__` name lookups through it, instead of carrying one ivar plus
    # one `when` arm per constructor.
    class ConstructorRegistry
      def initialize(map)
        @map = map.freeze
      end

      def [](name)
        @map[name]
      end

      def key?(name)
        @map.key?(name)
      end

      # The set of constructor names, e.g. for host-side enumeration / tests.
      def names
        @map.keys
      end
    end
  end
end
