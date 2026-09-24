# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG "queue a toggle event task", shared by the elements whose open state
    # fires one: `<details>` and `<dialog>`. The trusted ToggleEvent fires
    # asynchronously, and rapid changes coalesce into ONE event whose oldState is
    # the state before the first change and newState the state after the last.
    # A change while a task is still pending CANCELS that task and queues a fresh
    # one at the back of the queue, so the event arrives after everything queued
    # in between.
    module ToggleEventTask
      private

      # The same "queue a task" the toggle event uses (a `setTimeout(…, 0)` on the
      # document's scheduler, or a direct call when there is none). Any element
      # firing an async event shares it.
      def schedule_async(&block)
        scheduler = @document.respond_to?(:__internal_scheduler__) ? @document.__internal_scheduler__ : nil
        scheduler ? scheduler.set_timeout(block, 0) : block.call
      end

      def queue_toggle_event(old_open, new_open)
        @__toggle_old = old_open ? "open" : "closed" unless @__toggle_pending
        @__toggle_new = new_open ? "open" : "closed"
        @__toggle_pending = true
        @__toggle_announced = true
        generation = @__toggle_generation = (@__toggle_generation || 0) + 1
        schedule_async do
          next unless generation == @__toggle_generation

          @__toggle_pending = false
          dispatch_event(ToggleEvent.new("toggle",
            "oldState" => @__toggle_old, "newState" => @__toggle_new,
            "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
        end
      end
    end
  end
end
