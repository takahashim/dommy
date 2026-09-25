# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG's "toggle task tracker": the per-purpose state behind a coalescing
    # `toggle` event. `<details>`, `<dialog>`, and popovers each keep their OWN
    # tracker (a "details/dialog/popover toggle task tracker"), so an element
    # that participates in more than one purpose at once — a `<dialog
    # popover>` — fires one `toggle` event per purpose instead of merging them.
    #
    # There is no real task queue to remove a task FROM (Dommy has no
    # cancelable scheduled callback), so a superseded task is instead left to
    # run and no-op: #begin_run bumps a generation counter, and the task it
    # schedules must check #current? before firing.
    class ToggleTaskTracker
      def initialize
        @pending = false
        @generation = 0
        @old_state = nil
        @announced = false
      end

      # Whether this purpose has ever queued a toggle event for the element —
      # what HTMLDetailsElement's insertion steps ask, to tell an element the
      # parser opened (which owes a toggle it never had an attribute change to
      # fire from) from one an attribute change already announced.
      attr_reader :announced

      # The old_state a run in progress started from, once #begin_run has been
      # called.
      attr_reader :old_state

      # Begin (or extend) a coalescing run: a change already pending keeps its
      # ORIGINAL old_state, so a rapid closed->open->closed collapses into one
      # event spanning first-old to last-new rather than firing per change.
      # Returns the generation the caller's scheduled task must present back
      # to #current? to know whether it is still the latest one queued.
      def begin_run(old_state)
        @old_state = old_state unless @pending
        @pending = true
        @announced = true
        @generation += 1
      end

      # Whether `generation` (as returned by #begin_run) is still the latest —
      # false means a later change superseded it, so the task it belongs to
      # must not fire.
      def current?(generation) = generation == @generation

      # The scheduled task for the current generation is running: the run it
      # belongs to is no longer pending.
      def finish
        @pending = false
      end
    end
  end
end
