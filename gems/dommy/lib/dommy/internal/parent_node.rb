# frozen_string_literal: true

module Dommy
  module Internal
    # Shared ParentNode tree-mutation surface for Element, Fragment, and
    # ShadowRoot. Includers must expose `@__node__` (the backing Nokogiri
    # node) and `@document` (the owning Dommy::Document).
    #
    # All child-list mutations funnel through `notify_child_list`, which
    # forwards to MutationCoordinator#notify_child_list_mutation. That
    # coordinator already no-ops on empty added/removed sets and on an
    # unwrappable target, so callers may invoke it unconditionally.
    module ParentNode
      # `appendChild(child)` — detach the node(s) from any current parent
      # and append to the end of this node's child list.
      def append_child(child)
        check_insertion!(child)
        nodes = detach_dom_nodes(child)
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
        child
      end

      # ParentNode#append — mixed Node/String args appended in order.
      def append(*args)
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
        nil
      end

      # ParentNode#prepend — insert before the current first child.
      def prepend(*args)
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        anchor = @__node__.children.first
        if anchor
          nodes.reverse_each { |n| anchor.add_previous_sibling(n) }
        else
          nodes.each { |n| @__node__.add_child(n) }
        end
        notify_child_list(added: nodes)
        nil
      end

      # ParentNode#replaceChildren — remove all existing children, then
      # append the new set. One mutation record carries both sides.
      def replace_children(*args)
        removed = @__node__.children.to_a
        removed.each(&:unlink)
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes, removed: removed)
        nil
      end

      private

      # Centralized MutationObserver childList notification. Defaults the
      # target to this node; beforebegin/afterend/replaceWith/outerHTML
      # callers pass the parent explicitly. The coordinator filters out
      # empty added/removed sets, so this is always safe to call.
      def notify_child_list(added: [], removed: [], target: @__node__)
        @document.notify_child_list_mutation(
          target_node: target,
          added_nodes: added,
          removed_nodes: removed
        )
      end

      # Coerce an append/prepend/replaceChildren argument into raw Nokogiri
      # node(s), detached from any current parent:
      #   - Element / TextNode / CommentNode → its backing node (unlinked)
      #   - Fragment                          → its extracted children
      #   - String                            → a fresh text node
      #   - anything else with a backing node → that node (unlinked)
      #
      # The class constants resolve at call time, so the mixin only needs to
      # be defined before the including class bodies run.
      def detach_dom_nodes(value)
        case value
        when Element, TextNode, CommentNode
          node = value.__dommy_backend_node__
          node.unlink if node.parent
          [node]
        when Fragment
          value.extract_children
        when String
          [@document.create_text_node(value).__dommy_backend_node__]
        else
          node = value.respond_to?(:__dommy_backend_node__) ? value.__dommy_backend_node__ : nil
          return [] unless node

          node.unlink if node.parent
          [node]
        end
      end

      # Hierarchy guard hook. Default no-op (Fragment / ShadowRoot stay
      # permissive, matching current behavior). Element overrides this to
      # call its `check_hierarchy!`.
      def check_insertion!(_child)
        nil
      end
    end
  end
end
