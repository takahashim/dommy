# frozen_string_literal: true

module Dommy
  module Internal
    # A document's popover bookkeeping (HTML §6.12): the showing auto and hint
    # popover lists, the flags that keep one popover's show or hide from
    # starting another's, and the algorithms that close a stack down to a
    # given popover.
    #
    # HTML derives the two lists from the top layer, in the order the
    # popovers entered it. Dommy has no top layer, so each list is kept in
    # that order directly: a popover joins its list when it is shown in auto
    # or hint mode and leaves it when it is hidden.
    #
    # The popovers themselves are Internal::ElementPopover hosts, which this
    # calls back through #__internal_hide_popover__ and
    # #__internal_popover_opened_mode__.
    class PopoverStack
      # The document's "showing popover", "hiding popover nesting count" and
      # "hint stack parent".
      attr_accessor :showing_popover, :hiding_nesting_count, :hint_stack_parent

      def initialize
        @lists = { "auto" => [], "hint" => [] }
        @showing_popover = false
        @hiding_nesting_count = 0
        @hint_stack_parent = nil
      end

      # The showing auto ("auto") or hint ("hint") popover list, as a copy.
      def list(mode) = @lists.fetch(mode).dup

      def include?(mode, element) = !position(@lists.fetch(mode), element).nil?

      def add(element, mode)
        @lists.fetch(mode) << element
        nil
      end

      def remove(element)
        @lists.each_value { |list| list.reject! { |p| p.equal?(element) } }
        nil
      end

      # HTML's "topmost auto or hint popover".
      def topmost_auto_or_hint = @lists["hint"].last || @lists["auto"].last

      # HTML's "topmost popover ancestor": the last showing auto or hint
      # popover that `node` (or `source`, the element that showed it) sits
      # inside in the flat tree, or nil.
      def topmost_ancestor(node, source)
        combined = @lists["auto"] + @lists["hint"]
        index = [node, source].compact.map do |n|
          combined.rindex { |popover| flat_tree_descendant?(n, popover) } || -1
        end.max
        index.nil? || index.negative? ? nil : combined[index]
      end

      # HTML's "hide popovers until": close the hint stack down to `endpoint`,
      # then the auto stack down to it — or, when `endpoint` is a hint popover,
      # down to the auto popover the hint stack hangs from. A nil `endpoint`
      # closes everything.
      def hide_popovers_until(endpoint, focus_previous_element, fire_events)
        endpoint_is_hint = include?("hint", endpoint)
        hide_stack_until(endpoint, "hint", focus_previous_element, fire_events)
        auto_endpoint = endpoint_is_hint ? @hint_stack_parent : endpoint
        hide_stack_until(auto_endpoint, "auto", focus_previous_element, fire_events)
        nil
      end

      # HTML's "hide popover stack until": hide everything above `endpoint`
      # in the `mode` list, topmost first, then hide quietly whatever a
      # beforetoggle listener showed meanwhile.
      def hide_stack_until(endpoint, mode, focus_previous_element, fire_events)
        popovers = list(mode)
        endpoint_index = position(popovers, endpoint)
        last_hide_index = endpoint_index ? endpoint_index + 1 : 0
        to_remain = popovers[0, last_hide_index]
        popovers[last_hide_index..].reverse_each do |popover|
          popover.__internal_hide_popover__(focus_previous_element, fire_events, false)
        end
        list(mode).reverse_each do |popover|
          next if position(to_remain, popover)

          popover.__internal_hide_popover__(focus_previous_element, false, false)
        end
        nil
      end

      private

      # Elements are compared by identity: a node's wrapper is unique, and an
      # element's == may mean something else.
      def position(list, element) = element && list.index { |p| p.equal?(element) }

      def flat_tree_descendant?(node, ancestor)
        current = flat_tree_parent(node)
        until current.nil?
          return true if current.equal?(ancestor)

          current = flat_tree_parent(current)
        end
        false
      end

      # A node's parent in the flat tree: a shadow root's host stands in for
      # the root, and a shadow host's child hangs from the slot it is
      # assigned to — or from nothing, unslotted. The walk ends at the
      # document, which no popover can be.
      def flat_tree_parent(node)
        parent = node.parent_node
        return parent.host if parent.is_a?(ShadowRoot)
        return nil unless parent.is_a?(Element)
        return parent unless parent.__internal_shadow_root__

        node.respond_to?(:assigned_slot) ? node.assigned_slot : nil
      end
    end
  end
end
