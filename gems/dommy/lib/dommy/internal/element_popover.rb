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

      # `showPopover(options)`: HTML's "show popover", throwing, with the
      # options' `source` as the element that showed it.
      def show_popover(options = nil)
        __internal_show_popover__(true, popover_source(options))
      end

      # HTML's "show popover" given throwExceptions and a source (the
      # invoker that showed it, or nil).
      def __internal_show_popover__(throw_exceptions, source = nil)
        document = @document
        stack = document.__internal_popover_stack__
        if stack.showing_popover || stack.hiding_nesting_count != 0
          raise DOMException::InvalidStateError, "another popover is being shown or hidden" if throw_exceptions

          return nil
        end
        return nil unless popover_valid?(false, nil, throw_exceptions)

        stack.showing_popover = true
        begin
          return nil unless fire_beforetoggle(false, true, source)
          # The listener may have disconnected the element or changed its
          # popover attribute.
          return nil unless popover_valid?(false, document, throw_exceptions)

          should_restore_focus = false
          original_mode = popover
          mode = original_mode
          ancestor = nil
          if mode == "auto" || mode == "hint"
            ancestor = stack.topmost_ancestor(self, source)
            # A hint popover cannot be the parent of an auto one, so an auto
            # popover nested in a hint one opens as a hint.
            mode = "hint" if ancestor&.__internal_popover_opened_mode__ == "hint"
            stack.hide_stack_until(ancestor, "hint", should_restore_focus, true)
            stack.hide_stack_until(ancestor, "auto", should_restore_focus, true) if mode == "auto"
            # Hiding those fired their beforetoggle, whose listeners may have
            # changed this element too.
            unless popover == original_mode
              raise DOMException::InvalidStateError, "the popover attribute changed while showing" if throw_exceptions

              return nil
            end
            return nil unless popover_valid?(false, document, throw_exceptions)

            # Only the first popover of a stack gives the focus back.
            should_restore_focus = stack.topmost_auto_or_hint.nil?
            @__popover_opened_mode__ = mode
          end
          @__previously_focused_element__ = nil
          originally_focused = document.__internal_focused_element__
          stack.add(self, mode) if @__popover_opened_mode__
          stack.hint_stack_parent = ancestor if mode == "hint" && ancestor&.__internal_popover_opened_mode__ == "auto"
          @__popover_open__ = true
          @__popover_trigger__ = source
          @document.__internal_note_selector_state_change__
          popover_focusing_steps
          @__previously_focused_element__ = originally_focused if should_restore_focus && !popover.nil?
          queue_toggle_event(popover_toggle_tracker, false, true, source)
        ensure
          stack.showing_popover = false
        end
        nil
      end

      def hide_popover = __internal_hide_popover__(true, true, true)

      # The element that showed this popover (HTML's "popover trigger"), or
      # nil.
      def __internal_popover_trigger__ = @__popover_trigger__

      # `togglePopover(force)`, `force` a boolean or `{force:}`: hide when
      # showing and not forced open, else show unless forced shut; forced shut
      # while hidden, only check that the call is valid. Answers whether the
      # popover is showing.
      def toggle_popover(options = nil)
        force = popover_force(options)
        source = options.is_a?(Hash) ? popover_source(options) : nil
        if popover_showing? && force != true
          hide_popover
        elsif force != false
          # Already showing and forced open, the show steps' own check finds
          # nothing to do and returns quietly.
          __internal_show_popover__(true, source)
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
      def __internal_hide_popover__(focus_previous_element, fire_events, throw_exceptions, forced: false, source: nil)
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
            fire_beforetoggle(true, false, source)
            return nil unless popover_valid?(true, nil, throw_exceptions, forced: forced)
          end

          stack.remove(self)
          @__popover_trigger__ = nil
          @__popover_opened_mode__ = nil
          @__popover_open__ = false
          @document.__internal_note_selector_state_change__
          stack.hint_stack_parent = nil if stack.hint_stack_parent.equal?(self) || stack.list("hint").empty?
          queue_toggle_event(popover_toggle_tracker, true, false, source) if fire_events
          previously_focused = @__previously_focused_element__
          if previously_focused
            @__previously_focused_element__ = nil
            focused = @document.__internal_focused_element__
            if focus_previous_element && focused && Retargeting.shadow_including_inclusive_ancestor?(self, focused)
              Focusability.run_focusing_steps(previously_focused)
            end
          end
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

      # HTML's "check popover validity" given expectedToBeShowing and no
      # expected document, with an exception read as false.
      def __internal_popover_valid__?(expected_showing) = popover_valid?(expected_showing, nil, false)

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
        when "showPopover" then show_popover(args[0])
        when "hidePopover" then hide_popover
        when "togglePopover" then toggle_popover(args[0])
        else super
        end
      end

      private

      # ShowPopoverOptions' `source`, an HTMLElement (TypeError for anything
      # else, null included), or nil when the options carry none.
      def popover_source(options)
        return nil unless options.is_a?(Hash)

        key = ["source", :source].find { |k| options.key?(k) }
        return nil if key.nil?

        value = options[key]
        return nil if value.equal?(Bridge::UNDEFINED)
        # Not nullable: null is no HTMLElement either.
        raise Bridge::TypeError, "source is not of type 'HTMLElement'" unless value.is_a?(HTMLElement)

        value
      end

      # HTML's "popover focusing steps": a dialog runs its own; otherwise the
      # popover itself when it has autofocus, else its autofocus delegate,
      # takes the focus, and the page's autofocus is then settled.
      def popover_focusing_steps
        return __internal_dialog_focusing_steps__ if respond_to?(:__internal_dialog_focusing_steps__)

        control = __internal_has_attribute__?("autofocus") ? self : Focusability.autofocus_delegate(self, "other")
        return if control.nil?

        Focusability.run_focusing_steps(control)
        @document.__internal_autofocus_done__
      end

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
