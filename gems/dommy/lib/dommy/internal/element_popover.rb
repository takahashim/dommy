# frozen_string_literal: true

require_relative "toggle_events"

module Dommy
  module Internal
    # HTML's popover API, which HTMLElement has and no other element does:
    # showPopover, hidePopover and togglePopover fire beforetoggle and
    # toggle (Internal::ToggleEvents; nothing renders).
    #
    # Host contract: #dispatch_event (plus what ToggleEvents asks of it).
    module ElementPopover
      include ToggleEvents

      JS_METHOD_NAMES = %w[showPopover hidePopover togglePopover].freeze

      def show_popover
        return nil if popover_showing?
        return nil unless fire_beforetoggle(false, true)

        @__popover_open__ = true
        queue_toggle_event(popover_toggle_tracker, false, true)
        nil
      end

      def hide_popover
        return nil unless popover_showing?

        fire_beforetoggle(true, false)
        @__popover_open__ = false
        queue_toggle_event(popover_toggle_tracker, true, false)
        nil
      end

      def toggle_popover
        popover_showing? ? hide_popover : show_popover
        popover_showing?
      end

      def __js_call__(method, args)
        case method
        when "showPopover" then show_popover
        when "hidePopover" then hide_popover
        when "togglePopover" then toggle_popover
        else super
        end
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
