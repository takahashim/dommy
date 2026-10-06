# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's PopoverTargetAttributes mixin (button and input): the
    # `popovertarget` element reference, the `popovertargetaction` keyword,
    # and the "popover target attribute activation behavior" a button-like
    # control runs when it is activated.
    #
    # Host contract: an HTMLElement (ReflectedAttributes' reflect_element),
    # #__internal_actually_disabled__,
    # #form, and #__internal_popover_invoker_button__? (whether the element
    # is a "button": a button element, or an input of a button type) and
    # #__internal_submit_button_state__? (whether it is a submit button,
    # disabled or not).
    module PopoverInvokerElement
      POPOVER_TARGET_ACTIONS = {
        attr: "popovertargetaction", js: "popoverTargetAction",
        keywords: %w[toggle show hide], missing: "toggle", invalid: "toggle"
      }.freeze

      def self.included(base)
        base.reflect_enumerated popover_target_action: POPOVER_TARGET_ACTIONS
        # `popoverTargetElement` ([Reflect="popovertarget"] Element?).
        base.reflect_element popover_target_element: "popovertarget"
      end

      # HTML "get the popover target element": nil unless this is a button
      # that is not disabled and not a submit button with a form owner, and
      # its popovertarget-associated element is a popover.
      def __internal_popover_target_element__
        return nil unless __internal_popover_invoker_button__?
        return nil if __internal_actually_disabled__
        return nil if form && __internal_submit_button_state__?

        target = popover_target_element
        target.is_a?(HTMLElement) && !target.popover.nil? ? target : nil
      end

      private

      # HTML "popover target attribute activation behavior", `event_target`
      # being the activating event's target.
      def run_popover_target_activation(event_target)
        popover = __internal_popover_target_element__
        return if popover.nil?
        # A click from inside the popover, on an invoker that contains it,
        # does nothing (the popover is a descendant of its own invoker).
        if event_target.is_a?(Node) && Retargeting.shadow_including_inclusive_ancestor?(popover, event_target) &&
            !popover.equal?(self) && Retargeting.shadow_including_inclusive_ancestor?(self, popover)
          return
        end

        showing = popover.__internal_popover_showing__?
        action = popover_target_action
        return if action == "show" && showing
        return if action == "hide" && !showing

        if showing
          popover.__internal_hide_popover__(true, true, false, source: self)
        elsif popover.__internal_popover_valid__?(false)
          popover.__internal_show_popover__(false, self)
        end
      end
    end
  end
end
