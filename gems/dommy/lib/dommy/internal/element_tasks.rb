# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's "queue an element task": run the block later, as a task of its
    # own — a `setTimeout(…, 0)` on the document's scheduler, or right away
    # when there is none.
    #
    # Host contract: @document.
    module ElementTasks
      private

      def queue_element_task(&block)
        scheduler = @document.respond_to?(:__internal_scheduler__) ? @document.__internal_scheduler__ : nil
        scheduler ? scheduler.set_timeout(block, 0) : block.call
      end
    end
  end
end
