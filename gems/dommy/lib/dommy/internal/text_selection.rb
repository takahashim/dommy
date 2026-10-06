# frozen_string_literal: true

module Dommy
  module Internal
    # The text-selection API a form control exposes: `selectionStart`,
    # `selectionEnd`, `selectionDirection`, `setSelectionRange`, `select`,
    # `setRangeText` (HTML §4.10.20, "APIs for the text control selections").
    #
    # HTML gives `<input>` (for the types that hold a single line of text) and
    # `<textarea>` the same algorithms, over the control's "relevant value" —
    # an input's value, a textarea's API value — measured in UTF-16 code units.
    # Every control starts with a text entry cursor at the beginning (0); the
    # value setters move it to the end when they change the value.
    #
    # A host provides `value` (the relevant value) and
    # `__internal_set_relevant_value__(string)` (setRangeText's edit, which
    # sets the dirty value flag), and narrows #supports_selection? when only
    # some of its states have a selection.
    module TextSelection
      include ElementTasks

      SELECTION_MODES = %w[select start end preserve].freeze

      # Whether this control has a text selection at all. `<textarea>` always
      # does; `<input>` only for the types that hold one line of text.
      def supports_selection? = true

      def selection_start
        return nil unless supports_selection?

        sync_selection
        @__selection_start
      end

      # HTML: the end moves up to a start set past it; then "set the selection
      # range" with the current direction.
      def selection_start=(index)
        require_selection!
        start = selection_offset(index)
        finish = selection_end
        finish = start if start && finish < start
        set_selection_range(start, finish, selection_direction)
      end

      def selection_end
        return nil unless supports_selection?

        sync_selection
        @__selection_end
      end

      def selection_end=(index)
        require_selection!
        set_selection_range(selection_start, selection_offset(index), selection_direction)
      end

      def selection_direction
        return nil unless supports_selection?

        @__selection_direction || "none"
      end

      def selection_direction=(direction)
        require_selection!
        set_selection_range(selection_start, selection_end, direction)
      end

      # `setSelectionRange(start, end, direction)` — the IDL's unsigned longs
      # (so -1 is 4294967295, past any value's end).
      def set_selection_range(start, finish, direction = nil)
        require_selection!
        __internal_set_selection_range__(selection_offset(start), selection_offset(finish), direction)
      end

      # HTML "set the selection range": a null start or end is 0, offsets past
      # the end (`:infinity` included) point at the end, an end at or before
      # the start collapses the selection there, and a direction other than
      # "forward" / "backward" is "none". When that changed the selection,
      # queue a task to fire a bubbling `select` event at the element.
      def __internal_set_selection_range__(start, finish, direction = nil)
        sync_selection
        length = Utf16.length(value.to_s)
        start = start.nil? ? 0 : [start == :infinity ? length : start, length].min
        finish = finish.nil? ? 0 : [finish == :infinity ? length : finish, length].min
        start = finish if finish <= start
        direction = %w[forward backward].include?(direction) ? direction : "none"
        previous = [@__selection_start, @__selection_end, selection_direction]
        @__selection_start = start
        @__selection_end = finish
        @__selection_direction = direction
        return nil if previous == [start, finish, direction]

        queue_element_task do
          dispatch_event(Event.new("select", "bubbles" => true).__internal_mark_trusted__)
        end
        nil
      end

      # `select()` — the whole value. A control without a selection ignores it.
      def select
        return nil unless supports_selection?

        __internal_set_selection_range__(0, :infinity)
      end

      # `setRangeText(replacement)` / `setRangeText(replacement, start, end,
      # selectMode = "preserve")`: replace the code units between start and
      # end (by default the selection) with `replacement`, set the dirty value
      # flag, and place the selection by `selectMode`.
      def set_range_text(replacement, start = nil, finish = nil, select_mode = nil, explicit_range: !start.nil?)
        require_selection!
        replacement = replacement.to_s
        sync_selection
        if explicit_range
          start = selection_offset(start)
          finish = selection_offset(finish)
        else
          start = @__selection_start
          finish = @__selection_end
        end
        raise DOMException::IndexSizeError, "The start offset is greater than the end offset." if start > finish

        units = utf16_units(value.to_s)
        start = [start, units.length].min
        finish = [finish, units.length].min
        selection_start = @__selection_start
        selection_end = @__selection_end

        inserted = utf16_units(replacement)
        units[start...finish] = inserted
        __internal_set_relevant_value__(utf16_string(units))
        @__selection_snapshot = value.to_s

        new_end = start + inserted.length
        case (explicit_range ? select_mode || "preserve" : "preserve")
        when "select"
          selection_start = start
          selection_end = new_end
        when "start"
          selection_start = selection_end = start
        when "end"
          selection_start = selection_end = new_end
        else
          delta = inserted.length - (finish - start)
          selection_start = preserved_offset(selection_start, start, finish, delta, start)
          selection_end = preserved_offset(selection_end, start, finish, delta, new_end)
        end
        __internal_set_selection_range__(selection_start, selection_end)
      end

      # `setRangeText` from script: the overloads take one argument, or three
      # or four (two is a TypeError), and `selectMode` is a SelectionMode.
      def __internal_js_set_range_text__(args)
        case [args.length, 4].min
        when 1 then set_range_text(args[0])
        when 3, 4
          mode = args[3]
          mode = nil if mode.equal?(Bridge::UNDEFINED)
          unless mode.nil? || SELECTION_MODES.include?(mode.to_s)
            raise Bridge::TypeError, "The provided value '#{mode}' is not a valid enum value of type SelectionMode."
          end

          set_range_text(args[0], args[1], args[2], mode&.to_s, explicit_range: true)
        else
          raise Bridge::TypeError, "Failed to execute 'setRangeText': No function was found that matched the signature provided."
        end
      end

      # The value setters' "move the text entry cursor position to the end of
      # the text control, unselecting any selected text and resetting the
      # selection direction to none" — called only when the value changed.
      def __internal_move_cursor_to_end__
        current = value.to_s
        length = Utf16.length(current)
        @__selection_start = length
        @__selection_end = length
        @__selection_direction = "none"
        @__selection_snapshot = current
        nil
      end

      # The cursor back at the beginning (an input whose type gains a
      # selection).
      def __internal_reset_selection__
        @__selection_start = 0
        @__selection_end = 0
        @__selection_direction = "none"
        @__selection_snapshot = nil
        nil
      end

      private

      # "Whenever the relevant value changes": a selection now past the end of
      # the value is pulled back to it. Dommy notices the change when the
      # selection is next read, comparing with the value it was last synced to.
      def sync_selection
        @__selection_start ||= 0
        @__selection_end ||= 0
        current = value.to_s
        return if current == @__selection_snapshot

        length = Utf16.length(current)
        @__selection_start = [@__selection_start, length].min
        @__selection_end = [@__selection_end, length].min
        @__selection_snapshot = current
      end

      # Pull the selection back to `length` (an intermediate value the control
      # had between two observations).
      def clamp_selection_to(length)
        sync_selection
        @__selection_start = [@__selection_start, length].min
        @__selection_end = [@__selection_end, length].min
      end

      # setRangeText's "preserve": an offset past the replaced range shifts by
      # the change in length; one inside it snaps to `snap`.
      def preserved_offset(offset, start, finish, delta, snap)
        return offset + delta if offset > finish
        return snap if offset > start

        offset
      end

      # Raise on a selection setter for a control that has none (an `<input
      # type=checkbox>`). The default never raises, because a control that
      # includes this and does not narrow #supports_selection? always has one.
      def require_selection!
        return if supports_selection?

        raise DOMException::InvalidStateError, "This element does not support selection."
      end

      # An offset argument converted to the IDL's `unsigned long` (null stays
      # null, for the nullable attributes).
      def selection_offset(index)
        return nil if index.nil? || index.equal?(Bridge::UNDEFINED)
        return index if index == :infinity

        WebIDL.unsigned_long(index)
      end

      def utf16_units(string)
        string.encode(Encoding::UTF_16LE).unpack("v*")
      end

      # A lone surrogate (a range that split a pair) becomes U+FFFD.
      def utf16_string(units)
        units.pack("v*").force_encoding(Encoding::UTF_16LE)
             .encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end
  end
end
