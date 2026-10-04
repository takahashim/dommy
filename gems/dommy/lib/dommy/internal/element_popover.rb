# frozen_string_literal: true

require_relative "toggle_events"

module Dommy
  module Internal
    # HTML's popover API, which HTMLElement has and no other element does:
    # showPopover, hidePopover and togglePopover fire beforetoggle and
    # toggle (Internal::ToggleEvents; nothing renders), on an element whose
    # popover attribute makes it a popover.
    #
    # Host contract: an HTMLElement — #popover (the enumerated reflection),
    # #dispatch_event, #is_connected? and @document responding to
    # #fullscreen_element (plus what ToggleEvents asks of it).
    module ElementPopover
      include ToggleEvents

      JS_METHOD_NAMES = %w[showPopover hidePopover togglePopover].freeze

      def show_popover
        return nil unless popover_valid?(expected_showing: false)
        return nil unless fire_beforetoggle(false, true)

        @__popover_open__ = true
        queue_toggle_event(popover_toggle_tracker, false, true)
        nil
      end

      def hide_popover
        return nil unless popover_valid?(expected_showing: true)

        fire_beforetoggle(true, false)
        @__popover_open__ = false
        queue_toggle_event(popover_toggle_tracker, true, false)
        nil
      end

      # `togglePopover(force)`, `force` a boolean or `{force:}`: hide when
      # showing and not forced open, show when hidden and not forced shut;
      # otherwise only check that the call is valid. Answers whether the
      # popover is showing.
      def toggle_popover(options = nil)
        force = popover_force(options)
        if popover_showing? && force != true
          hide_popover
        elsif !popover_showing? && force != false
          show_popover
        else
          popover_valid?(expected_showing: popover_showing?)
        end
        popover_showing?
      end

      def __js_call__(method, args)
        case method
        when "showPopover" then show_popover
        when "hidePopover" then hide_popover
        when "togglePopover" then toggle_popover(args[0])
        else super
        end
      end

      private

      # The `force` of `(TogglePopoverOptions or boolean)`: a boolean converts
      # with ToBoolean (togglePopover(1) shows, togglePopover(0) hides); null
      # and undefined pick the dictionary, an empty one; a dictionary's
      # `force`, when present and not undefined, converts too ({force: null}
      # hides). nil when there is none, and the call toggles.
      def popover_force(options)
        return nil if options.nil? || options.equal?(Bridge::UNDEFINED)
        return WebIDL.boolean(options) unless options.is_a?(Hash)

        key = ["force", :force].find { |k| options.key?(k) }
        key.nil? || options[key].equal?(Bridge::UNDEFINED) ? nil : WebIDL.boolean(options[key])
      end

      # HTML's "popover showing state" is showing — what <dialog>'s
      # showModal() checks, without reaching into this module's state.
      def popover_showing? = @__popover_open__ ? true : false

      # HTML's "check popover validity", throwing: NotSupportedError for an
      # element that is no popover, false when it is already in the state the
      # call would leave it in, InvalidStateError when it cannot be one now —
      # disconnected, an open modal dialog, or in fullscreen.
      def popover_valid?(expected_showing:)
        raise DOMException::NotSupportedError, "the element has no popover attribute" if popover.nil?
        return false unless popover_showing? == expected_showing

        if !is_connected? || (is_a?(HTMLDialogElement) && __internal_modal__?) ||
            @document.fullscreen_element.equal?(self)
          raise DOMException::InvalidStateError, "the element cannot be a popover now"
        end

        true
      end

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
