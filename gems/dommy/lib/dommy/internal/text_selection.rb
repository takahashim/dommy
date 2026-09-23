# frozen_string_literal: true

module Dommy
  module Internal
    # The text-selection API a form control exposes: `selectionStart`,
    # `selectionEnd`, `selectionDirection`, `setSelectionRange`, `select`.
    #
    # HTML gives `<input>` (for the types that hold a single line of text) and
    # `<textarea>` the same algorithm. It was written once for input and stubbed
    # for textarea — `setSelectionRange` there returned nil and `selectionStart`
    # was not exposed at all — so a rich-text editor reading a textarea's
    # caret got nothing, quietly.
    #
    # Dommy does not render, so there is no caret a user moved; what the
    # selection reflects is what a script last set, defaulting to the end of the
    # value, which is what a freshly-focused control reports.
    module TextSelection
      # Whether this control has a text selection at all. `<textarea>` always
      # does; `<input>` only for the types that hold one line of text.
      def supports_selection? = true

      def selection_start
        return nil unless supports_selection?

        @__selection_start ||= value.to_s.length
      end

      def selection_start=(index)
        require_selection!
        @__selection_start = clamp_selection_index(index)
      end

      def selection_end
        return nil unless supports_selection?

        @__selection_end ||= value.to_s.length
      end

      def selection_end=(index)
        require_selection!
        @__selection_end = clamp_selection_index(index)
      end

      def selection_direction
        return nil unless supports_selection?

        @__selection_direction || "none"
      end

      def selection_direction=(direction)
        require_selection!
        @__selection_direction = normalize_selection_direction(direction)
      end

      # HTML "set the selection range": end is clamped to the value's length and
      # start is clamped to end, so start never runs past it.
      def set_selection_range(start, finish, direction = nil)
        require_selection!
        length = value.to_s.length
        last = clamp_selection_index(finish, length)
        @__selection_start = [clamp_selection_index(start, length), last].min
        @__selection_end = last
        @__selection_direction = normalize_selection_direction(direction)
        nil
      end

      # `select()` — the whole value.
      def select
        return nil unless supports_selection?

        set_selection_range(0, value.to_s.length)
      end

      # setRangeText replaces the selected text. Dommy keeps the selection but
      # does not edit the value here: the replacement's interaction with
      # `dirty value` and the input event is not modelled.
      def set_range_text(_replacement, *_)
        require_selection!
        nil
      end

      private

      # Raise on a selection setter for a control that has none (an `<input
      # type=checkbox>`). The default never raises, because a control that
      # includes this and does not narrow #supports_selection? always has one.
      def require_selection!
        return if supports_selection?

        raise DOMException::InvalidStateError, "This element does not support selection."
      end

      def clamp_selection_index(index, length = value.to_s.length)
        number = index.to_i
        number.negative? ? 0 : [number, length].min
      end

      def normalize_selection_direction(direction)
        text = direction.to_s
        %w[forward backward].include?(text) ? text : "none"
      end
    end
  end
end
