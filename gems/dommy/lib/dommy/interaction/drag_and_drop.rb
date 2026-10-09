# frozen_string_literal: true

module Dommy
  module Interaction
    # One mouse drag of a draggable element onto a target, after HTML's
    # drag-and-drop processing model (§6.11.5). The user's pointer is pressed
    # on the source already (EventSynthesis.drag_and_drop does that); this is
    # what follows when a drag begins:
    #
    #   dragstart at the source (canceling it means no drag), pointercancel
    #   for the pointer the drag took over, then for each place the pointer
    #   rests (over where it was pressed, then over the target): drag at the
    #   source, dragenter as the immediate user selection changes, dragleave
    #   at the target element it leaves, dragover at the current target
    #   element. The release drops on the current target element when the
    #   last dragover accepted the drop (and fires dragleave there when it did
    #   not), and dragend ends it at the source.
    #
    # Every event shares one drag data store, in :read_write mode for
    # dragstart, :read_only for drop and :protected otherwise. There is no
    # layout, so the coordinates are each element's bounding box center (the
    # origin when geometry is off).
    class DragAndDrop
      # The operations each `effectAllowed` value lets a drop make.
      ALLOWED_OPERATIONS = {
        "none" => [],
        "copy" => %w[copy],
        "copyLink" => %w[copy link],
        "copyMove" => %w[copy move],
        "link" => %w[link],
        "linkMove" => %w[link move],
        "move" => %w[move],
        "all" => %w[copy link move],
        "uninitialized" => %w[copy link move]
      }.freeze

      # `pause` runs where a browser's event loop gets a turn: between the
      # pointer's moves and before the release.
      def initialize(source, origin, pause: nil)
        @source = source
        @origin = origin
        @pause = pause
        @data_transfer = DataTransfer.new
        @current_target = nil
        @immediate_selection = nil
        @operation = "none"
      end

      # Drag onto `target`; returns whether the drop happened.
      def run(target)
        seed_data_store
        return false if fire("dragstart", @source, mode: :read_write).default_prevented?

        EventSynthesis.dispatch(@origin, PointerEvent.new("pointercancel",
          EventSynthesis.pointer_init(EventSynthesis.mouse_init.merge("cancelable" => false))))
        [@origin, target].each do |position|
          @pause&.call
          break unless move_to(position)
        end
        @pause&.call
        release
      end

      private

      # A link or an image carries its URL by default (HTML §6.11.5, "the
      # drag data item list").
      def seed_data_store
        url =
          case @source.local_name
          when "a" then @source.href
          when "img" then @source.src
          end
        return if url.to_s.empty?

        @data_transfer.set_data("text/uri-list", url)
        @data_transfer.set_data("text/plain", url)
      end

      # One iteration of the drag loop with the pointer over `element`.
      # Returns false when the page canceled the drag (a prevented `drag`).
      def move_to(element)
        if fire("drag", @source).default_prevented?
          @operation = "none"
          return false
        end

        change_selection(element) unless element.equal?(@immediate_selection)
        dragover if @current_target
        true
      end

      def change_selection(element)
        @immediate_selection = element
        entered = fire("dragenter", element, related: @current_target)
        target =
          if entered.default_prevented? || accepts_drops?(element)
            element
          else
            body_target
          end
        if @current_target && !target.equal?(@current_target)
          fire("dragleave", @current_target, related: target, cancelable: false)
        end
        @current_target = target
      end

      # Without a listener taking the drop, the body becomes the current
      # target element (it gets its own dragenter first).
      def body_target
        body = @origin.owner_document.body
        return nil unless body

        fire("dragenter", body, related: @current_target) unless body.equal?(@current_target)
        body
      end

      def dragover
        over = fire("dragover", @current_target)
        @operation =
          if over.default_prevented?
            allowed = ALLOWED_OPERATIONS.fetch(@data_transfer.effect_allowed, ALLOWED_OPERATIONS["all"])
            allowed.include?(@data_transfer.drop_effect) ? @data_transfer.drop_effect : "none"
          elsif accepts_drops?(@current_target)
            "copy"
          else
            "none"
          end
      end

      def release
        dropped = @operation != "none" && @current_target
        if dropped
          drop = fire("drop", @current_target, mode: :read_only, drop_effect: @operation)
          @operation = @data_transfer.drop_effect if drop.default_prevented?
        elsif @current_target
          fire("dragleave", @current_target, cancelable: false)
        end
        fire("dragend", @source, cancelable: false, drop_effect: @operation)
        dropped ? true : false
      end

      # A text field or an editable element takes a drop by default.
      def accepts_drops?(element)
        return true if element.is_a?(HTMLTextAreaElement)
        return true if element.is_a?(HTMLInputElement) && element.supports_selection?

        element.is_a?(Element) && Internal::ElementEditing.editable?(element)
      end

      # The dropEffect a drag event starts with: none for dragstart, drag and
      # dragleave; for dragenter and dragover the operation effectAllowed
      # suggests (the first it allows, link for a dragged link); for drop and
      # dragend the current drag operation (passed in).
      def initial_drop_effect(type)
        return "none" unless %w[dragenter dragover].include?(type)

        allowed = @data_transfer.effect_allowed
        return "link" if allowed == "uninitialized" && @source.local_name == "a" && @source.has_attribute?("href")

        ALLOWED_OPERATIONS.fetch(allowed, ALLOWED_OPERATIONS["all"]).first || "none"
      end

      def fire(type, element, related: nil, cancelable: true, mode: :protected, drop_effect: nil)
        @data_transfer.__internal_mode__ = mode
        @data_transfer.drop_effect = drop_effect || initial_drop_effect(type)
        x, y = center(element)
        init = EventSynthesis::BUBBLES.merge(
          "cancelable" => cancelable, "dataTransfer" => @data_transfer, "relatedTarget" => related,
          "button" => 0, "buttons" => 1, "clientX" => x, "clientY" => y
        )
        event = DragEvent.new(type, init)
        EventSynthesis.dispatch(element, event)
        event
      ensure
        @data_transfer.__internal_mode__ = :protected
      end

      def center(element)
        return [0, 0] unless element.respond_to?(:get_bounding_client_rect)

        rect = element.get_bounding_client_rect
        [rect.left + (rect.width / 2.0), rect.top + (rect.height / 2.0)]
      end
    end
  end
end
