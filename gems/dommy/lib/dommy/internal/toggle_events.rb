# frozen_string_literal: true

require_relative "element_tasks"
require_relative "toggle_task_tracker"

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
    # WHATWG gives `<details>`, `<dialog>`, and popovers each their OWN toggle
    # task tracker, so an element juggling more than one purpose at once (a
    # `<dialog popover>`) coalesces each purpose's rapid changes independently
    # rather than merging them into one event. Callers pass the
    # ToggleTaskTracker for the purpose they are queuing — see
    # HTMLDialogElement#dialog_toggle_tracker, HTMLDetailsElement's, and
    # ElementTopLayer#popover_toggle_tracker.
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

      def queue_toggle_event(tracker, old_open, new_open)
        new_state = toggle_state(new_open)
        generation = tracker.begin_run(toggle_state(old_open))
        queue_element_task do
          next unless tracker.current?(generation)

          tracker.finish
          dispatch_event(ToggleEvent.new("toggle",
            "oldState" => tracker.old_state, "newState" => new_state,
            "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
        end
      end

      def toggle_state(open) = open ? "open" : "closed"
    end
  end
end
