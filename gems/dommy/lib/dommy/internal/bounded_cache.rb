# frozen_string_literal: true

module Dommy
  module Internal
    # A memo with a cap, evicting least-recently-used.
    #
    # Two of these had grown separately — the parsed-sheet cache and the
    # query-result cache — and both dropped everything on reaching the cap,
    # which is the moment a cache is most needed: the 65th sheet threw away the
    # 64 the page was rebuilding from. One implementation, one eviction policy.
    #
    # Ruby's Hash preserves insertion order, so re-inserting on a hit is enough
    # to order the entries by recency.
    class BoundedCache
      attr_reader :capacity

      def initialize(capacity)
        @capacity = capacity
        @entries = {}
      end

      # The cached value for `key`, or the block's value, stored.
      def fetch(key)
        value = @entries.delete(key)
        return (@entries[key] = value) unless value.nil?

        store(key, yield)
      end

      def [](key)
        value = @entries.delete(key)
        @entries[key] = value unless value.nil?
        value
      end

      def store(key, value)
        @entries.shift while @entries.size >= @capacity
        @entries[key] = value
      end
      alias_method :[]=, :store

      def clear
        @entries.clear
        self
      end

      def size = @entries.size
    end
  end
end
