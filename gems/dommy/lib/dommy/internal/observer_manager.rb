# frozen_string_literal: true

module Dommy
  module Internal
    # Manages MutationObserver registration and matching.
    # Filters observers based on mutation target to avoid unnecessary lookups.
    class ObserverManager
      def initialize
        @observers = []
      end

      def register(observer)
        @observers << observer unless @observers.include?(observer)
      end

      def unregister(observer)
        @observers.delete(observer)
      end

      # Returns all observers that match the given wrapped target.
      # Delegates to each observer's matches_wrapped? method.
      def observers_matching(target_wrapped)
        @observers.select { |observer| observer.matches_wrapped?(target_wrapped) }
      end

      # The same observers, in the order WHATWG reaches their registrations:
      # walking the target's inclusive ancestors from the target upward. Ties
      # (several registrations on the same node) keep registration order.
      def observers_matching_in_order(target_wrapped)
        chain = ObserverMatcher.inclusive_ancestors(target_wrapped)
        observers_matching(target_wrapped).sort_by.with_index do |observer, index|
          [observer.matching_chain_index(chain, target_wrapped) || chain.size, index]
        end
      end

      def all
        @observers.dup
      end

      # True when at least one observer is registered — a cheap gate so a
      # mutation with no observers skips building MutationRecords entirely.
      def any?
        !@observers.empty?
      end
    end
  end
end
