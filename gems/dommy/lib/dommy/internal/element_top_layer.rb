# frozen_string_literal: true

require_relative "toggle_events"

module Dommy
  module Internal
    # Putting an element in the top layer, and taking it back out: the popover
    # state machine and the fullscreen request. Neither renders anything here —
    # what they produce is the event pair and the state a script reads back.
    #
    # Host contract: #dispatch_event, and @document responding to
    # #__internal_set_fullscreen_element__ / #default_view (plus what
    # ToggleEvents asks of it).
    module ElementTopLayer
      include ToggleEvents

      def request_fullscreen
        @document.__internal_set_fullscreen_element__(self)
        PromiseValue.resolve(@document.default_view, nil)
      end

      # Popover API — show / hide / toggle fire beforetoggle + toggle events
      # (Internal::ToggleEvents; no real visual change). Return values mirror
      # the IDL.
      def show_popover
        return nil if @__popover_open__
        return nil unless fire_beforetoggle(false, true)

        @__popover_open__ = true
        queue_toggle_event(popover_toggle_tracker, false, true)
        nil
      end

      def hide_popover
        return nil unless @__popover_open__

        fire_beforetoggle(true, false)
        @__popover_open__ = false
        queue_toggle_event(popover_toggle_tracker, true, false)
        nil
      end

      def toggle_popover
        @__popover_open__ ? hide_popover : show_popover
        @__popover_open__ ? true : false
      end

      private

      # HTML's "popover showing state" is showing — what <dialog>'s
      # showModal() checks, without reaching into this module's state.
      def popover_showing? = @__popover_open__ ? true : false

      # This element's own "popover toggle task tracker" — separate from any
      # "dialog toggle task tracker" the same element also has as a
      # `<dialog popover>`, so the two purposes' rapid changes coalesce
      # independently rather than merging into one event.
      def popover_toggle_tracker
        @__popover_toggle_tracker ||= ToggleTaskTracker.new
      end
    end
  end
end
