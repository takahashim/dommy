# frozen_string_literal: true

module Dommy
  module Internal
    # DOM's "queue a mutation observer microtask" and "notify mutation
    # observers", for one window (Dommy's stand-in for the agent): a single
    # microtask, queued by the first record or slot signal, that hands each
    # pending observer its records — in the order they became pending, which
    # is the order "queue a mutation record" reached their registrations —
    # and then fires `slotchange` at the signal slots, in the order they were
    # signaled.
    #
    # Spec: https://dom.spec.whatwg.org/#notify-mutation-observers
    class MutationObserverMicrotask
      def initialize(scheduler)
        @scheduler = scheduler
        @observers = []
        @signal_slots = []
        @queued = false
      end

      # DOM "append observer to the pending mutation observers": `observer`
      # was handed a record.
      def observer_pending(observer)
        @observers << observer unless @observers.any? { |o| o.equal?(observer) }
        queue
      end

      # DOM "signal a slot change".
      def signal_slot(slot)
        @signal_slots << slot unless @signal_slots.any? { |s| s.equal?(slot) }
        queue
      end

      private

      def queue
        return if @queued

        @queued = true
        @scheduler.queue_microtask(proc { notify })
      end

      def notify
        @queued = false
        observers = @observers
        @observers = []
        slots = @signal_slots
        @signal_slots = []
        observers.each(&:__internal_notify__)
        slots.each { |slot| slot.dispatch_event(Event.new("slotchange", "bubbles" => true).__internal_mark_trusted__) }
      end
    end
  end
end
