# frozen_string_literal: true

module Dommy
  module Internal
    # The popover state machine and the fullscreen request beside it —
    # both are 'show this element on top', and neither renders anything here.
    #
    # Element's, but not about being an element: it was 2200 lines holding
    # these four subjects alongside attributes, selectors and serialization.
    module ElementPopover
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

      # Popover state — modern HTML pattern. `show`/`hide`/`toggle`
      # fire `beforetoggle` and `toggle` events (no real visual change).
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
