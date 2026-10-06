# frozen_string_literal: true

module Dommy
  module Internal
    # HTML §6.6.3/§6.6.5 sequential focus navigation — what Tab and
    # Shift+Tab do: the document's sequential focus navigation order (its
    # flattened tabindex-ordered focus navigation scope), the sequential
    # navigation search algorithm, and the steps that move the focus
    # forward or backward from the focused area or the sequential focus
    # navigation starting point.
    #
    # Focus navigation scopes: the Document; a shadow host (its shadow
    # tree's elements); a slot (the elements assigned to it); and the popover
    # trigger of a showing popover, whose contents are navigated right after
    # the trigger. In each scope, elements with a positive tabindex come
    # first, in increasing order, then those with tabindex 0 or none, in
    # shadow-including tree order; a scope owner that is no focusable area
    # (a slot, a host that delegates focus) stands for its scope's contents.
    #
    # Dommy has no browser controls to hand the focus to past either end of
    # the order, so — as HTML allows a user agent without such controls —
    # navigation restarts from the document there and wraps around. Child
    # navigables are not entered: an iframe is a focusable area like any
    # other, since Dommy keeps a frame's focus out of its parent's.
    module SequentialFocusNavigation
      module_function

      # Move the focus as the user's Tab (`direction` :forward) or Shift+Tab
      # (:backward) in `document` does. Answers the element focused, or nil.
      def navigate(document, direction)
        focused = document.__internal_focused_element__
        starting_point = focused || document
        point = document.__internal_sequential_focus_navigation_starting_point__
        if point && point_usable?(point, document) &&
            (focused.nil? || Retargeting.shadow_including_inclusive_ancestor?(focused, point))
          starting_point = point
        end

        restarted = false
        loop do
          order = navigation_order(document)
          mechanism = starting_point.equal?(document) || order.any? { |e| e.equal?(starting_point) } ? :sequential : :dom
          candidate = search(document, order, starting_point, direction, mechanism)
          if candidate
            document.__internal_with_focus_type__(:keyboard) { Focusability.run_focusing_steps(candidate) }
            return candidate
          end

          document.__internal_sequential_focus_navigation_starting_point__ = nil
          # No controls of our own to move to: start over from the document.
          return nil if restarted || starting_point.equal?(document)

          restarted = true
          starting_point = document
        end
      end

      # The sequential navigation search algorithm over `order` (the
      # document's sequential focus navigation order).
      def search(document, order, starting_point, direction, mechanism)
        suitable = order.select { |element| suitable?(element) }
        if starting_point.equal?(document)
          return direction == :forward ? suitable.first : suitable.last
        end

        if mechanism == :sequential
          index = order.index { |e| e.equal?(starting_point) }
          before = order[0...index]
          after = order[(index + 1)..]
          return direction == :forward ? after.find { |e| suitable?(e) } : before.reverse.find { |e| suitable?(e) }
        end

        # DOM: the suitable area nearest the starting point in shadow-including
        # tree order.
        positions = tree_positions(document)
        start = positions[starting_point]
        return nil if start.nil?

        ranked = suitable.filter_map { |e| (pos = positions[e]) && [pos, e] }
        if direction == :forward
          ranked.select { |pos, _| pos > start }.min_by(&:first)&.last
        else
          ranked.select { |pos, _| pos < start }.max_by(&:first)&.last
        end
      end

      # HTML "suitable sequentially focusable area": not inert, and
      # sequentially focusable.
      def suitable?(element) = !Focusability.inert?(element) && Focusability.sequentially_focusable?(element)

      # The document's sequential focus navigation order: its flattened
      # tabindex-ordered focus navigation scope.
      def navigation_order(document)
        root = document.document_element
        return [] if root.nil?

        triggers = {}.compare_by_identity
        each_element(root) do |element|
          triggers[element.__internal_popover_trigger__] = true if popover_with_trigger?(element)
        end
        scopes = {}.compare_by_identity
        collect(root, document, scopes)
        flatten(document, scopes, {}.compare_by_identity, triggers)
      end

      # Every element of the shadow-including tree under `element`.
      def each_element(element, &block)
        yield element
        shadow = element.respond_to?(:__internal_shadow_root__) ? element.__internal_shadow_root__ : nil
        shadow&.children&.to_a&.each { |child| each_element(child, &block) }
        element.children.to_a.each { |child| each_element(child, &block) }
      end

      # Walk the shadow-including tree, filing each element under its
      # associated focus navigation owner (HTML's algorithm), in tree order.
      def collect(element, owner, scopes)
        owner = element.__internal_popover_trigger__ if popover_with_trigger?(element)
        (scopes[owner] ||= []) << element

        shadow = element.respond_to?(:__internal_shadow_root__) ? element.__internal_shadow_root__ : nil
        if shadow
          shadow.children.to_a.each { |child| collect(child, element, scopes) }
          element.children.to_a.each do |child|
            slot = child.respond_to?(:assigned_slot) ? child.assigned_slot : nil
            collect(child, slot, scopes) if slot
          end
        elsif slot?(element) && in_shadow_tree?(element)
          # Fallback content is not rendered while the slot has assigned
          # nodes; otherwise it is the slot's scope. (HTML's owner algorithm
          # would file it under the slot's own owner; browsers and WPT's
          # shadow-dom/focus-navigation tests navigate it as the slot's.)
          element.children.to_a.each { |child| collect(child, element, scopes) } if element.assigned_nodes.to_a.empty?
        else
          element.children.to_a.each { |child| collect(child, owner, scopes) }
        end
      end

      # HTML "flattened tabindex-ordered focus navigation scope" of `owner`.
      def flatten(owner, scopes, visited, triggers)
        visited[owner] = true
        result = []
        tabindex_ordered(scopes[owner] || [], triggers).each do |item|
          if scope_owner?(item, triggers) && !visited[item]
            result << item if Focusability.focusable_area?(item)
            result.concat(flatten(item, scopes, visited, triggers))
          else
            result << item
          end
        end
        result
      end

      # HTML "tabindex-ordered focus navigation scope": the scope owners and
      # focusable areas of a scope, minus those with a negative tabindex,
      # positive tabindex values first in increasing order, then the rest;
      # tree order otherwise.
      def tabindex_ordered(members, triggers)
        kept = members.select do |element|
          next false unless scope_owner?(element, triggers) || Focusability.focusable_area?(element)

          value = Focusability.tabindex_value(element)
          value.nil? || value >= 0
        end
        kept.each_with_index.sort_by do |element, index|
          value = Focusability.tabindex_value(element) || 0
          value.positive? ? [0, value, index] : [1, 0, index]
        end.map(&:first)
      end

      # HTML "focus navigation scope owner" (an element one: the Document is
      # the root's owner).
      def scope_owner?(element, triggers)
        return true if element.respond_to?(:__internal_shadow_root__) && element.__internal_shadow_root__
        return true if slot?(element)

        triggers.key?(element)
      end

      def slot?(element) = element.is_a?(HTMLSlotElement)

      def in_shadow_tree?(element) = element.get_root_node.is_a?(ShadowRoot)

      def popover_with_trigger?(element)
        element.respond_to?(:__internal_popover_trigger__) && element.__internal_popover_showing__? &&
          !element.__internal_popover_trigger__.nil?
      end

      def point_usable?(point, document)
        point.respond_to?(:owner_document) && point.owner_document.equal?(document) && point.is_connected?
      end

      # Each node's position in shadow-including tree order.
      def tree_positions(document)
        positions = {}.compare_by_identity
        counter = 0
        walk = lambda do |node|
          positions[node] = (counter += 1)
          shadow = node.respond_to?(:__internal_shadow_root__) ? node.__internal_shadow_root__ : nil
          walk.call(shadow) if shadow
          node.child_nodes.to_a.each { |child| walk.call(child) } if node.respond_to?(:child_nodes)
        end
        walk.call(document)
        positions
      end

      private_class_method :search, :suitable?, :each_element, :collect, :flatten, :tabindex_ordered,
        :scope_owner?, :slot?, :in_shadow_tree?, :popover_with_trigger?, :point_usable?, :tree_positions
    end
  end
end
