# frozen_string_literal: true

module Dommy
  module Internal
    # Putting an element in the top layer, and taking it back out: the popover
    # state machine and the fullscreen request. Neither renders anything here —
    # what they produce is the event pair and the state a script reads back.
    #
    # Host contract: #dispatch_event, and @document responding to
    # #__internal_set_fullscreen_element__ / #default_view.
    module ElementTopLayer
      def request_fullscreen
        @document.__internal_set_fullscreen_element__(self)
        PromiseValue.resolve(@document.default_view, nil)
      end

      # Popover API — show / hide / toggle fire beforetoggle + toggle events
      # (no real visual change). Return values mirror the IDL.
      def show_popover
        toggle_popover_state(true)
        nil
      end

      def hide_popover
        toggle_popover_state(false)
        nil
      end

      def toggle_popover
        new_state = !@__popover_open__
        toggle_popover_state(new_state)
        new_state
      end

      private

      # The transition itself: `beforetoggle`, then the new state, then
      # `toggle`. Private, because the three methods above are the ways in —
      # a caller that sets the state without the events has skipped the API.
      def toggle_popover_state(open)
        old_state = @__popover_open__ ? "open" : "closed"
        new_state = open ? "open" : "closed"
        return if old_state == new_state

        dispatch_event(
          CustomEvent.new(
            "beforetoggle",
            "detail" => {"oldState" => old_state, "newState" => new_state}
          )
        )
        @__popover_open__ = open
        dispatch_event(
          CustomEvent.new(
            "toggle",
            "detail" => {"oldState" => old_state, "newState" => new_state}
          )
        )
      end
    end
  end
end
