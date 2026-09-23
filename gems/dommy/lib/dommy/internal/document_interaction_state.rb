# frozen_string_literal: true

module Dommy
  module Internal
    # What the user is pointing at: the active, focused and hovered elements.
    # They are not tree state, but :focus and :hover match on them, so a change
    # has to tell the selector caches.
    #
    # Document's, but its own subject: the class had thirty-one __internal_*
    # seams through which every collaborator reached its state.
    module DocumentInteractionState
      # Currently-focused element (or body if none). Updated via
      # `el.focus()` / `el.blur()`.
      def active_element
        @active_element || body
      end

      def __internal_set_active_element__(el)
        # Focus is selector-observable state (:focus / :focus-within rules), so
        # a change invalidates cached query results and computed styles.
        __internal_note_selector_state_change__ unless @active_element.equal?(el)
        @active_element = el
      end

      # The explicitly focused element (nil when nothing holds focus) — what
      # :focus matches. Distinct from #active_element, which falls back to
      # <body> per spec.
      def __internal_focused_element__
        @active_element
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
    end
  end
end
