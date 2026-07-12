# frozen_string_literal: true

module Dommy
  module Internal
    # Shared ChildNode surface (WHATWG DOM `before` / `after` / `replaceWith`)
    # plus the argument-coercion + childList-notification primitives those and
    # ParentNode's own mutators build on. Included by both ParentNode (Element /
    # Fragment / ShadowRoot) and the leaf CharacterData nodes (Text / Comment /
    # ProcessingInstruction) — a leaf can be moved with `before`/`after` but must
    # NOT gain `appendChild`/`insertBefore`, so those stay in ParentNode.
    #
    # Includers must expose `@__node__` (the backing node) and `@document`.
    module ChildNode
      # ChildNode#before — insert nodes as preceding siblings of `@__node__`.
      # Follows the spec's "viable previous sibling" dance: the reference child
      # is the first preceding sibling NOT among the argument nodes, resolved
      # AFTER the arguments are detached (converting them into a node removes
      # them from their old parents). Nodes are then inserted forward before the
      # (fixed) reference — reversing would emit them backwards.
      def child_node_before(args)
        parent = @__node__.parent
        return nil unless parent

        arg_nodes = backend_nodes_in(args)
        viable_prev = @__node__.previous_sibling
        viable_prev = viable_prev.previous_sibling while viable_prev && arg_nodes.any? { |n| n == viable_prev }

        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        ref = viable_prev.nil? ? parent.children.first : viable_prev.next_sibling
        insert_child_nodes(nodes, ref, parent)
        notify_child_list(added: nodes, target: parent)
        nil
      end

      # ChildNode#after — insert nodes as following siblings of `@__node__`.
      def child_node_after(args)
        parent = @__node__.parent
        return nil unless parent

        arg_nodes = backend_nodes_in(args)
        viable_next = @__node__.next_sibling
        viable_next = viable_next.next_sibling while viable_next && arg_nodes.any? { |n| n == viable_next }

        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        insert_child_nodes(nodes, viable_next, parent)
        notify_child_list(added: nodes, target: parent)
        nil
      end

      # ChildNode#replaceWith — replace `@__node__` with the given nodes.
      def child_node_replace_with(args)
        parent = @__node__.parent
        return nil unless parent

        arg_nodes = backend_nodes_in(args)
        viable_next = @__node__.next_sibling
        viable_next = viable_next.next_sibling while viable_next && arg_nodes.any? { |n| n == viable_next }

        removed = @__node__
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        if @__node__.parent == parent
          # `@__node__` survived the conversion (it wasn't among the arguments):
          # insert the new nodes before it, then unlink it — a true replace.
          nodes.each { |n| @__node__.add_previous_sibling(n) }
          @__node__.unlink
          notify_child_list(added: nodes, removed: [removed], target: parent)
        else
          # `@__node__` was itself an argument, so the conversion already moved
          # it into `nodes`; pre-insert the set before the viable next sibling.
          insert_child_nodes(nodes, viable_next, parent)
          notify_child_list(added: nodes, target: parent)
        end
        nil
      end

      # WebIDL nullable DOMString coercion (`DOMString?`): JS null and undefined
      # both become the null value, which callers treat as the empty string.
      def nullable_dom_string(value)
        return "" if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))

        value.to_s
      end

      private

      # Insert `nodes` (raw backend nodes) into `parent` before `ref`, or append
      # when `ref` is nil. Forward iteration against a fixed anchor preserves
      # document order.
      def insert_child_nodes(nodes, ref, parent)
        if ref
          nodes.each { |n| ref.add_previous_sibling(n) }
        else
          nodes.each { |n| parent.add_child(n) }
        end
      end

      # The backing nodes of any ChildNode arguments that are already Nodes
      # (strings / other values have none). Used to skip argument nodes when
      # locating the viable previous / next sibling.
      def backend_nodes_in(args)
        args.filter_map do |arg|
          arg.__dommy_backend_node__ if arg.respond_to?(:__dommy_backend_node__)
        end
      end

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

      # Coerce an append/prepend/replaceChildren/before/after argument into raw
      # backend node(s), detached from any current parent:
      #   - Element / TextNode / CommentNode → its backing node (unlinked)
      #   - Fragment                          → its extracted children
      #   - String                            → a fresh text node
      #   - anything else with a backing node → that node (unlinked)
      #
      # The class constants resolve at call time, so the mixin only needs to
      # be defined before the including class bodies run.
      def detach_dom_nodes(value)
        case value
        when Fragment
          value.extract_children.map { |n| adopt_into_document(n) }
        when String
          [@document.create_text_node(value).__dommy_backend_node__]
        else
          node = value.respond_to?(:__dommy_backend_node__) ? value.__dommy_backend_node__ : nil
          return [] unless node

          # WHATWG pre-insert adopts the node into this node's document before
          # linking it. libxml2 reassigns ownership in place during add_child, so
          # the explicit adopt is a no-op move there; Makiri can't move a node
          # between document arenas, so a cross-document insert must adopt (an
          # imported copy) first. adopt_node reseats the Dommy wrapper onto the
          # adopted node, so JS identity (`parent.appendChild(x); x` ===
          # `parent.lastChild`) survives. Same-document: the wrapper's backend
          # node is unchanged, so this is identical to the previous behavior.
          detach_with_notify(node)
          [@document.adopt_node(value).__dommy_backend_node__]
        end
      end

      # Bring a raw backend node into this node's document (WHATWG adopt). A
      # no-op when already same-document; otherwise Backend.adopt — in place for
      # Nokogiri, an imported copy for Makiri (which can't move nodes between
      # arenas). Used for fragment children, which have no standalone wrapper to
      # reseat.
      def adopt_into_document(node)
        target = @document.backend_doc
        node.document == target ? node : Backend.adopt(node, target)
      end

      # Detach a node from its current parent, queuing a childList removal
      # record on that old parent first (WHATWG "remove" runs before the
      # subsequent insert, so moving a node yields a removal record + an addition
      # record). Returns the raw node, ready to be re-linked.
      def detach_with_notify(node)
        old_parent = node.parent
        return node unless old_parent

        # Capture the position (as wrapped nodes — the coordinator records
        # explicit siblings verbatim) before unlinking.
        prev_sib = node.previous_sibling && @document.wrap_node(node.previous_sibling)
        next_sib = node.next_sibling && @document.wrap_node(node.next_sibling)
        node.unlink
        @document.notify_child_list_mutation(
          target_node: old_parent,
          added_nodes: [],
          removed_nodes: [node],
          previous_sibling: prev_sib,
          next_sibling: next_sib
        )
        node
      end
    end
  end
end
