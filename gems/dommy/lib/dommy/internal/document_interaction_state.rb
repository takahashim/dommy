# frozen_string_literal: true

module Dommy
  module Internal
    # What the user is pointing at: the active, focused and hovered elements.
    # They are not tree state, but :focus and :hover match on them, so a change
    # has to tell the selector caches.
    #
    # Host contract: #body, #document_element, #default_view, and
    # DocumentGenerations for the epoch bump a focus or hover change owes the
    # selector caches.
    module DocumentInteractionState
      # DocumentOrShadowRoot's `activeElement` for the document: the focused
      # element retargeted against the document — the outermost shadow host,
      # for an element inside a shadow tree — or, with the viewport focused,
      # the body element, else the document element.
      def active_element
        focused = @active_element
        if focused
          candidate = Retargeting.retarget(focused, self)
          return candidate if candidate.respond_to?(:get_root_node) && candidate.get_root_node.equal?(self)
        end
        body || document_element
      end

      # Designate `el` (nil for the viewport) as the focused area, firing
      # nothing — what the focus fixup does, and what the focus update steps
      # do between their blur and focus events.
      def __internal_set_active_element__(el)
        # Focus is selector-observable state (:focus / :focus-within rules), so
        # a change invalidates cached query results and computed styles.
        return if @active_element.equal?(el)

        @active_element = el
        __internal_note_selector_state_change__
      end

      # The explicitly focused element (nil when the viewport has the focus) —
      # the focused area's DOM anchor when it is an element.
      def __internal_focused_element__
        @active_element
      end

      # HTML's "focus update steps" from the focused area to `new_element`
      # (nil, the viewport): blur and focusout at the element losing focus,
      # then focus and focusin at the one gaining it, each a trusted
      # FocusEvent whose relatedTarget is the other element.
      #
      # Whether the new focus is indicated (`:focus-visible`) is decided
      # first, from how it moved (#__internal_with_focus_type__).
      def __internal_focus_update__(new_element)
        old = @active_element
        type = @pending_focus_type || :script
        explicit = @pending_focus_visible
        # Focus moved by the handlers of the events below is script focus.
        @pending_focus_type = nil
        @pending_focus_visible = nil
        return nil if old.equal?(new_element)

        fire_focus_event(old, "blur", new_element) if old
        fire_focus_event(old, "focusout", new_element) if old
        if new_element
          @focus_visible = focus_indicated?(new_element, type, explicit)
          @last_focus_type = type unless type == :script
          # Sequential navigation goes on from the newly focused element.
          @__internal_sequential_focus_navigation_starting_point__ = new_element
        else
          @focus_visible = false
        end
        __internal_set_active_element__(new_element)
        return nil unless new_element

        fire_focus_event(new_element, "focus", old)
        fire_focus_event(new_element, "focusin", old)
        nil
      end

      # Run the block — focusing steps — as focus moved by `type`: :keyboard
      # (sequential focus navigation), :mouse (a click) or :script, and with
      # FocusOptions' `focusVisible` when the caller passed one.
      def __internal_with_focus_type__(type, focus_visible: nil)
        saved = [@pending_focus_type, @pending_focus_visible]
        @pending_focus_type = type
        @pending_focus_visible = focus_visible
        yield
      ensure
        @pending_focus_type, @pending_focus_visible = saved
      end

      # Whether the user agent indicates the focus of the focused element:
      # what `:focus-visible` matches on.
      def __internal_focus_visible__? = @focus_visible && @active_element ? true : false

      # `focus({focusVisible: true})` on the element already focused still
      # indicates its focus.
      def __internal_indicate_focus__
        return nil if @focus_visible || @active_element.nil?

        @focus_visible = true
        __internal_note_selector_state_change__
        nil
      end

      # The input modality the focus heuristics remember: a key press makes
      # later script focus visible, a pointer press undoes that.
      def __internal_note_keyboard_input__
        @had_keyboard_event = true
        nil
      end

      def __internal_note_pointer_input__
        @had_keyboard_event = false
        nil
      end

      # HTML's removing steps, for the focus: when the focused element, or
      # a shadow-including ancestor of it, leaves the document, the viewport
      # becomes the focused area. No blur fires (the "focus fixup").
      def __internal_focused_subtree_removed__(element)
        focused = @active_element
        return nil unless focused
        return nil unless Retargeting.shadow_including_inclusive_ancestor?(element, focused)

        __internal_set_active_element__(nil)
        nil
      end

      # The modal dialogs in the top layer, in the order they entered it.
      # The last one blocks the document: everything outside it is inert.
      def __internal_add_modal_dialog__(dialog)
        (@modal_dialogs ||= []).reject! { |d| d.equal?(dialog) }
        @modal_dialogs << dialog
        __internal_note_selector_state_change__
        nil
      end

      def __internal_remove_modal_dialog__(dialog)
        return nil unless @modal_dialogs&.any? { |d| d.equal?(dialog) }

        @modal_dialogs.reject! { |d| d.equal?(dialog) }
        __internal_note_selector_state_change__
        nil
      end

      # HTML "blocked by a modal dialog": the topmost dialog in the top layer.
      def __internal_blocking_modal_dialog__ = @modal_dialogs&.last

      # HTML's "open dialogs list": the open, connected dialogs, in the order
      # their dialog setup steps ran (a copy).
      def __internal_open_dialogs__ = (@open_dialogs ||= []).dup

      def __internal_add_open_dialog__(dialog)
        (@open_dialogs ||= []) << dialog unless @open_dialogs&.any? { |d| d.equal?(dialog) }
        nil
      end

      def __internal_remove_open_dialog__(dialog)
        @open_dialogs&.reject! { |d| d.equal?(dialog) }
        nil
      end

      # HTML's "sequential focus navigation starting point": a node, or nil
      # when unset (Internal::SequentialFocusNavigation).
      attr_accessor :__internal_sequential_focus_navigation_starting_point__

      # HTML's "popover pointerdown target" and "dialog pointerdown target",
      # which light dismiss records on a press (Internal::LightDismiss).
      attr_accessor :__internal_popover_pointerdown_target__, :__internal_dialog_pointerdown_target__

      # HTML's steps for an element with an autofocus attribute inserted into
      # a document: unless the top-level document has already processed its
      # autofocus, the element joins (or moves to the end of) its autofocus
      # candidates, which the next rendering update flushes.
      def __internal_autofocus_inserted__(element)
        return nil unless default_view.is_a?(Window)

        top = __internal_top_document__
        return nil if top.__internal_autofocus_processed__

        top.__internal_add_autofocus_candidate__(element)
        nil
      end

      def __internal_add_autofocus_candidate__(element)
        candidates = (@autofocus_candidates ||= [])
        candidates.reject! { |e| e.equal?(element) }
        candidates << element
        __internal_schedule_rendering_update__(:before)
        nil
      end

      def __internal_autofocus_processed__ = @autofocus_processed ? true : false

      # What the dialog and popover focusing steps do once they have focused
      # something: the page's autofocus is settled.
      def __internal_autofocus_done__
        top = __internal_top_document__
        top.instance_variable_set(:@autofocus_candidates, [])
        top.instance_variable_set(:@autofocus_processed, true)
        nil
      end

      # The active document of this document's top-level traversable: up
      # through the frames that host it.
      def __internal_top_document__
        document = self
        seen = 0
        while (view = document.default_view).respond_to?(:frame_element) && (frame = view.frame_element) &&
            (seen += 1) < 64
          document = frame.owner_document
        end
        document
      end

      # Ask for the next rendering update (Scheduler#request_rendering_update),
      # once per phase: before the frame's rAF callbacks it flushes the
      # autofocus candidates, after them it runs the focus fixup.
      def __internal_schedule_rendering_update__(phase = :after)
        pending = (@rendering_update_pending ||= {})
        return nil if pending[phase]

        view = default_view
        return nil unless view.is_a?(Window) && view.document.equal?(self)

        pending[phase] = true
        view.scheduler.request_rendering_update(lambda do
          pending.delete(phase)
          phase == :before ? flush_autofocus_candidates : focus_fixup
        end, phase: phase)
        nil
      end

      # The element the (virtual) pointer hovers — :hover matches it and its
      # ancestors. Set from tests or capybara-dommy's Node#hover; nil clears.
      def __internal_hovered_element__
        @hovered_element
      end

      def __internal_set_hovered_element__(el)
        return if @hovered_element.equal?(el)

        @hovered_element = el
        __internal_note_selector_state_change__
        nil
      end

      private

      # Input types whose controls take keyboard input (they would bring up
      # a virtual keyboard).
      KEYBOARD_INPUT_TYPES = %w[text search url tel email password number date month week time
                                datetime-local].freeze

      # Selectors' suggested heuristics for when to indicate focus: an
      # explicit `focusVisible` wins; keyboard focus is indicated; a click
      # indicates it only on an element that takes keyboard input; script
      # focus is indicated unless the last focus came from a pointer with no
      # key pressed since — or the element takes keyboard input.
      def focus_indicated?(element, type, explicit)
        return explicit unless explicit.nil?

        case type
        when :keyboard then true
        when :mouse then keyboard_input?(element)
        else @last_focus_type != :mouse || @had_keyboard_event || keyboard_input?(element)
        end
      end

      def keyboard_input?(element)
        return true if Focusability.editing_host?(element)
        return false unless element.namespace_uri == Namespaces::HTML

        case element.local_name
        when "textarea" then true
        when "input" then KEYBOARD_INPUT_TYPES.include?(element.type.to_s)
        else false
        end
      end

      # HTML's focus fixup (in "update the rendering"): a focused element
      # that stopped being a focusable area (disabled, hidden, made inert)
      # gives the focus to the viewport, firing blur.
      def focus_fixup
        focused = @active_element
        __internal_focus_update__(nil) if focused && !Focusability.focusable_area?(focused)
      end

      # HTML "flush autofocus candidates", for a top-level document: the
      # first candidate that is (or delegates to) a focusable area takes the
      # focus — unless something is focused already or the document has a
      # target element, which settles the matter without focusing anything.
      def flush_autofocus_candidates
        return if @autofocus_processed

        candidates = @autofocus_candidates
        return if candidates.nil? || candidates.empty?

        if @active_element || Internal.target_id(self)
          candidates.clear
          @autofocus_processed = true
          return
        end

        until candidates.empty?
          element = candidates.shift
          doc = element.owner_document
          next unless element.is_connected? && doc.__internal_top_document__.equal?(self)
          next if Internal.target_id(doc)

          target = Focusability.focusable_area?(element) ? element : Focusability.focusable_area_for(element)
          next if target.nil?

          candidates.clear
          @autofocus_processed = true
          target == :viewport ? __internal_focus_update__(nil) : Focusability.run_focusing_steps(target)
        end
      end

      # HTML "fire a focus event": a FocusEvent with the related target, the
      # window as its view, and the composed flag; focusin and focusout
      # (UI Events) bubble.
      def fire_focus_event(target, type, related)
        bubbles = type == "focusin" || type == "focusout"
        view = default_view
        event = FocusEvent.new(type, "bubbles" => bubbles, "composed" => true, "relatedTarget" => related,
          "view" => view.is_a?(Window) ? view : nil)
        target.dispatch_event(event.__internal_mark_trusted__)
      end
    end
  end
end
