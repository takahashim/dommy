# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's light dismiss: "run light dismiss activities" for a trusted
    # pointerdown or pointerup — "light dismiss open popovers" (§6.12) and
    # "light dismiss open dialogs" (the dialog element). Pointer Events calls
    # it as the user presses and releases the pointer, before the pointer
    # event is dispatched; Dommy's Interaction layer does the same for its
    # clicks.
    #
    # A press records the topmost popover (and the nearest open dialog) the
    # pointer went down in; the release, when it lands in the same one,
    # closes the auto and hint popovers above it, and requests to close the
    # topmost `closedby=any` dialog when that is not the dialog clicked.
    module LightDismiss
      module_function

      # Run light dismiss activities for `event` (a trusted PointerEvent of
      # type pointerdown or pointerup) aimed at `target`. `backdrop` says the
      # pointer hit a modal dialog's ::backdrop rather than its box — the
      # coordinates were outside the dialog.
      def run(event, target, backdrop: false)
        return unless event.__js_get__("isTrusted") == true
        return unless target.is_a?(Node)

        light_dismiss_open_popovers(event.type, target)
        light_dismiss_open_dialogs(event.type, target, backdrop)
        nil
      end

      # HTML "light dismiss open popovers".
      def light_dismiss_open_popovers(type, target)
        document = target.owner_document
        stack = document.__internal_popover_stack__
        return if stack.topmost_auto_or_hint.nil?

        case type
        when "pointerdown"
          document.__internal_popover_pointerdown_target__ = topmost_clicked_popover(target)
        when "pointerup"
          ancestor = topmost_clicked_popover(target)
          same_target = ancestor.equal?(document.__internal_popover_pointerdown_target__)
          document.__internal_popover_pointerdown_target__ = nil
          return unless same_target

          stack.hide_popovers_until(ancestor, false, true)
        end
      end

      # HTML "light dismiss open dialogs".
      def light_dismiss_open_dialogs(type, target, backdrop)
        document = target.owner_document
        open_dialogs = document.__internal_open_dialogs__
        return if open_dialogs.empty?

        ancestor = nearest_clicked_dialog(target, backdrop)
        case type
        when "pointerdown"
          document.__internal_dialog_pointerdown_target__ = ancestor
        when "pointerup"
          same_target = ancestor.equal?(document.__internal_dialog_pointerdown_target__)
          document.__internal_dialog_pointerdown_target__ = nil
          return unless same_target

          topmost = open_dialogs.last
          return if ancestor.equal?(topmost)
          return unless topmost.closed_by == "any"

          topmost.__internal_request_close_watcher__(false)
        end
      end

      # HTML "nearest clicked dialog": nil for a hit on an open modal
      # dialog's backdrop, else the nearest open dialog among the target's
      # flat-tree inclusive ancestors.
      def nearest_clicked_dialog(target, backdrop)
        return nil if backdrop && open_dialog?(target) && target.__internal_modal__?

        node = target
        until node.nil?
          return node if open_dialog?(node)

          node = flat_tree_parent(node)
        end
        nil
      end

      # HTML "topmost clicked popover".
      def topmost_clicked_popover(node)
        clicked = nearest_inclusive_open_popover(node)
        target = nearest_inclusive_target_popover(node)
        stack_position(clicked) > stack_position(target) ? clicked : target
      end

      # HTML "nearest inclusive open popover".
      def nearest_inclusive_open_popover(node)
        current = node
        until current.nil?
          if current.respond_to?(:__internal_popover_opened_mode__) && current.__internal_popover_opened_mode__ &&
              current.__internal_popover_showing__?
            return current
          end

          current = flat_tree_parent(current)
        end
        nil
      end

      # HTML "nearest inclusive target popover".
      def nearest_inclusive_target_popover(node)
        current = node
        until current.nil?
          popover = target_popover(current)
          if popover && %w[auto hint].include?(popover.popover) && popover.__internal_popover_showing__?
            return popover
          end

          current = flat_tree_parent(current)
        end
        nil
      end

      # HTML "get the target popover": what a button's commandfor names, when
      # its command is a popover one, else its popover target element.
      def target_popover(node)
        return nil unless node.is_a?(HTMLElement)

        popover_target = node.respond_to?(:__internal_popover_target_element__) ? node.__internal_popover_target_element__ : nil
        return popover_target unless node.is_a?(HTMLButtonElement)
        return nil if node.__internal_actually_disabled__

        target = node.command_for_element
        return popover_target if target.nil?

        if node.form
          return nil if node.__internal_submit_button_state__?
          return nil if %w[reset auto].include?(node.type_state)
        end
        return nil unless HTMLButtonElement::POPOVER_COMMANDS.include?(node.command)
        return nil unless target.is_a?(HTMLElement) && !target.popover.nil?

        target
      end

      # HTML "get the popover stack position".
      def stack_position(popover)
        return 0 if popover.nil?

        stack = popover.owner_document.__internal_popover_stack__
        hint = stack.list("hint")
        auto = stack.list("auto")
        if (index = hint.index { |p| p.equal?(popover) })
          return index + auto.size + 1
        end
        if (index = auto.index { |p| p.equal?(popover) })
          return index + 1
        end

        0
      end

      def open_dialog?(node)
        node.is_a?(HTMLDialogElement) && node.__internal_has_attribute__?("open")
      end

      # A node's parent in the flat tree, up to the document element.
      def flat_tree_parent(node)
        parent = Focusability.flat_tree_parent(node)
        parent.is_a?(Element) ? parent : nil
      end

      private_class_method :light_dismiss_open_popovers, :light_dismiss_open_dialogs, :nearest_clicked_dialog,
        :topmost_clicked_popover, :nearest_inclusive_open_popover, :nearest_inclusive_target_popover,
        :target_popover, :stack_position, :open_dialog?, :flat_tree_parent
    end
  end
end
