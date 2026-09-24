# frozen_string_literal: true

require_relative "element_tasks"

module Dommy
  module Internal
    # The beforetoggle / toggle pair the elements with an open state fire:
    # `<details>` (toggle only), `<dialog>` and popovers.
    #
    # `beforetoggle` fires synchronously, before the state changes, and only an
    # opening one is cancelable. `toggle` fires asynchronously — WHATWG "queue a
    # toggle event task" — and rapid changes coalesce into ONE event whose
    # oldState is the state before the first change and newState the state
    # after the last. A change while a task is still pending CANCELS that task
    # and queues a fresh one at the back of the queue, so the event arrives
    # after everything queued in between.
    #
    # Host contract: #dispatch_event, and ElementTasks' @document.
    module ToggleEvents
      include ElementTasks

      private

      # False when a listener canceled an opening, so the caller aborts it.
      def fire_beforetoggle(old_open, new_open)
        dispatch_event(ToggleEvent.new("beforetoggle",
          "oldState" => toggle_state(old_open), "newState" => toggle_state(new_open),
          "bubbles" => false, "cancelable" => new_open).__internal_mark_trusted__)
      end

      def queue_toggle_event(old_open, new_open)
        @__toggle_old = toggle_state(old_open) unless @__toggle_pending
        @__toggle_new = toggle_state(new_open)
        @__toggle_pending = true
        @__toggle_announced = true
        generation = @__toggle_generation = (@__toggle_generation || 0) + 1
        queue_element_task do
          next unless generation == @__toggle_generation

          @__toggle_pending = false
          dispatch_event(ToggleEvent.new("toggle",
            "oldState" => @__toggle_old, "newState" => @__toggle_new,
            "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
        end
      end

      def toggle_state(open) = open ? "open" : "closed"
    end
  end
end
