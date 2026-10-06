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
      def __internal_focus_update__(new_element)
        old = @active_element
        return nil if old.equal?(new_element)

        fire_focus_event(old, "blur", new_element) if old
        fire_focus_event(old, "focusout", new_element) if old
        __internal_set_active_element__(new_element)
        return nil unless new_element

        fire_focus_event(new_element, "focus", old)
        fire_focus_event(new_element, "focusin", old)
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
