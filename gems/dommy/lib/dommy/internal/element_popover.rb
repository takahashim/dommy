# frozen_string_literal: true

require_relative "toggle_events"
require_relative "popover_stack"

module Dommy
  module Internal
    # HTML's popover API, which HTMLElement has and no other element does:
    # showPopover, hidePopover and togglePopover fire beforetoggle and
    # toggle (Internal::ToggleEvents; nothing renders), on an element whose
    # popover attribute makes it a popover. An auto or hint popover joins its
    # document's Internal::PopoverStack, so showing one closes the others it
    # is not nested in, and hiding one closes those shown above it.
    #
    # Host contract: an HTMLElement — #popover (the enumerated reflection),
    # #dispatch_event, #is_connected?, #parent_node and @document responding
    # to #fullscreen_element and #__internal_popover_stack__ (plus what
    # ToggleEvents asks of it).
    module ElementPopover
      include ToggleEvents

      JS_METHOD_NAMES = %w[showPopover hidePopover togglePopover].freeze

      # The popover attribute's states, for its reflection and its attribute
      # change steps: none without the attribute, auto for an empty one,
      # manual for any value that is no keyword.
      POPOVER_STATES = { keywords: %w[auto manual hint], missing: nil, empty: "auto",
                         invalid: "manual", nullable: true }.freeze

      # HTML's "show popover", throwing.
      def show_popover
        document = @document
        stack = document.__internal_popover_stack__
        if stack.showing_popover || stack.hiding_nesting_count != 0
          raise DOMException::InvalidStateError, "another popover is being shown or hidden"
        end
        return nil unless popover_valid?(false, nil, true)

        stack.showing_popover = true
        begin
          return nil unless fire_beforetoggle(false, true)
          # The listener may have disconnected the element or changed its
          # popover attribute.
          return nil unless popover_valid?(false, document, true)

          original_mode = popover
          mode = original_mode
          if mode == "auto" || mode == "hint"
            ancestor = stack.topmost_ancestor(self, nil)
            # A hint popover cannot be the parent of an auto one, so an auto
            # popover nested in a hint one opens as a hint.
            mode = "hint" if ancestor&.__internal_popover_opened_mode__ == "hint"
            stack.hide_stack_until(ancestor, "hint", false, true)
            stack.hide_stack_until(ancestor, "auto", false, true) if mode == "auto"
            # Hiding those fired their beforetoggle, whose listeners may have
            # changed this element too.
            unless popover == original_mode
              raise DOMException::InvalidStateError, "the popover attribute changed while showing"
            end
            return nil unless popover_valid?(false, document, true)

            @__popover_opened_mode__ = mode
            stack.add(self, mode)
            stack.hint_stack_parent = ancestor if mode == "hint" && ancestor&.__internal_popover_opened_mode__ == "auto"
          end
          @__popover_open__ = true
          @document.__internal_note_selector_state_change__
          queue_toggle_event(popover_toggle_tracker, false, true)
        ensure
          stack.showing_popover = false
        end
        nil
      end

      def hide_popover = __internal_hide_popover__(true, true, true)

      # `togglePopover(force)`, `force` a boolean or `{force:}`: hide when
      # showing and not forced open, else show unless forced shut; forced shut
      # while hidden, only check that the call is valid. Answers whether the
      # popover is showing.
      def toggle_popover(options = nil)
        force = popover_force(options)
        if popover_showing? && force != true
          hide_popover
        elsif force != false
          # Already showing and forced open, the show steps' own check finds
          # nothing to do and returns quietly.
          show_popover
        else
          popover_valid?(popover_showing?, nil, true)
        end
        popover_showing?
      end

      # HTML's "hide popover algorithm". Hiding an auto or hint popover first
      # hides the popovers shown above it in its stack. `forced` is the hide
      # an element's own removing or attribute change steps run: it has to
      # end the showing state even though the validity checks would turn it
      # away, for being disconnected or for having lost its popover
      # attribute, as browsers do.
      def __internal_hide_popover__(focus_previous_element, fire_events, throw_exceptions, forced: false)
        return nil unless popover_valid?(true, nil, throw_exceptions, forced: forced)

        stack = @document.__internal_popover_stack__
        nested_hide = @__popover_hiding__
        @__popover_hiding__ = true
        fire_events = false if nested_hide
        stack.hiding_nesting_count += 1
        begin
          if @__popover_opened_mode__
            in_hint = stack.include?("hint", self)
            in_auto = stack.include?("auto", self)
            stack.hide_stack_until(self, "hint", focus_previous_element, fire_events) if in_hint
            # Hiding the auto popover the hint stack hangs from hides every
            # hint popover.
            stack.hide_stack_until(nil, "hint", focus_previous_element, fire_events) if stack.hint_stack_parent.equal?(self)
            stack.hide_stack_until(self, "auto", focus_previous_element, fire_events) if in_auto
            return nil unless popover_valid?(true, nil, throw_exceptions, forced: forced)
          end
          if fire_events
            fire_beforetoggle(true, false)
            return nil unless popover_valid?(true, nil, throw_exceptions, forced: forced)
          end

          stack.remove(self)
          @__popover_opened_mode__ = nil
          @__popover_open__ = false
          @document.__internal_note_selector_state_change__
          stack.hint_stack_parent = nil if stack.hint_stack_parent.equal?(self) || stack.list("hint").empty?
          queue_toggle_event(popover_toggle_tracker, true, false) if fire_events
        ensure
          @__popover_hiding__ = false unless nested_hide
          stack.hiding_nesting_count -= 1
        end
        nil
      end

      # The mode an auto or hint popover was shown in — "auto" or "hint" — or
      # nil: HTML's "opened in popover mode".
      def __internal_popover_opened_mode__ = @__popover_opened_mode__

      # Whether the popover visibility state is showing, for :popover-open.
      def __internal_popover_showing__? = popover_showing?

      # HTML's removing steps for an element that may be a popover: it hides,
      # without events.
      def __internal_popover_removed__
        __internal_hide_popover__(false, false, false, forced: true) unless popover.nil?
        nil
      end

      # HTML's attribute change steps for every HTML element: a showing
      # popover whose popover attribute changes state hides.
      def __internal_attribute_changed__(name, old_value, new_value, namespace)
        if namespace.nil? && name == "popover" && popover_showing? &&
            enumerated_state_keyword(old_value, POPOVER_STATES) != enumerated_state_keyword(new_value, POPOVER_STATES)
          __internal_hide_popover__(true, true, false, forced: true)
        end
        defined?(super) ? super : nil
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

      # HTML's "check popover validity", with its exception thrown only when
      # `throw_exceptions` asks for it and false otherwise: NotSupportedError
      # for an element that is no popover, false when it is already in the
      # state the call would leave it in, InvalidStateError when it cannot be
      # one now — disconnected, moved to a document other than
      # `expected_document`, an open modal dialog, or in fullscreen. A
      # `forced` hide (#__internal_hide_popover__) passes without the popover
      # attribute and disconnected.
      def popover_valid?(expected_showing, expected_document, throw_exceptions, forced: false)
        raise DOMException::NotSupportedError, "the element has no popover attribute" if popover.nil? && !forced
        return false unless popover_showing? == expected_showing

        if (!forced && !is_connected?) || (expected_document && !@document.equal?(expected_document)) ||
            (is_a?(HTMLDialogElement) && __internal_modal__?) || @document.fullscreen_element.equal?(self)
          raise DOMException::InvalidStateError, "the element cannot be a popover now"
        end

        true
      rescue DOMException
        raise if throw_exceptions

        false
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
