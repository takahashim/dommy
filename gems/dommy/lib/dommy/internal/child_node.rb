# frozen_string_literal: true

require_relative "insertion_point"

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
      # Follows the spec's "viable previous sibling" dance: the viable previous
      # sibling is the first preceding sibling NOT among the argument nodes,
      # found before the arguments are converted into a node, and the reference
      # child is its next sibling AFTER (converting them moves them). Nodes are
      # then inserted forward before the (fixed) reference — reversing would
      # emit them backwards.
      def child_node_before(args)
        parent = @__node__.parent
        return nil unless parent

        arg_nodes = backend_nodes_in(args)
        viable_prev = InsertionPoint.skip_args_backwards(@__node__.previous_sibling, arg_nodes)
        args = InsertionPoint.convert_nodes_into_a_node(@document, args)
        ref = InsertionPoint.skip_args(reference_after(parent, viable_prev), arg_nodes)
        ensure_parent_insertion_validity!(parent, args, ref)
        record_previous = insertion_previous_sibling(parent, ref)
        record_next = wrap_sibling(ref)
        nodes = convert_for_insert(args, parent, ref)
        ref = reference_after(parent, viable_prev)
        insert_child_nodes(nodes, ref, parent)
        notify_child_list(added: nodes, target: parent,
                          previous_sibling: record_previous, next_sibling: record_next)
        nil
      end

      # ChildNode#after — insert nodes as following siblings of `@__node__`.
      def child_node_after(args)
        parent = @__node__.parent
        return nil unless parent

        arg_nodes = backend_nodes_in(args)
        viable_next = InsertionPoint.skip_args(@__node__.next_sibling, arg_nodes)
        args = InsertionPoint.convert_nodes_into_a_node(@document, args)

        ensure_parent_insertion_validity!(parent, args, viable_next)
        record_previous = insertion_previous_sibling(parent, viable_next)
        record_next = wrap_sibling(viable_next)
        nodes = convert_for_insert(args, parent, viable_next)
        insert_child_nodes(nodes, viable_next, parent)
        notify_child_list(added: nodes, target: parent,
                          previous_sibling: record_previous, next_sibling: record_next)
        nil
      end

      # ChildNode#replaceWith — replace `@__node__` with the given nodes.
      def child_node_replace_with(args)
        parent = @__node__.parent
        return nil unless parent

        arg_nodes = backend_nodes_in(args)
        viable_next = InsertionPoint.skip_args(@__node__.next_sibling, arg_nodes)
        args = InsertionPoint.convert_nodes_into_a_node(@document, args)

        # Step 5: when this node is still parent's child, it is replaced;
        # otherwise the conversion moved it — it was one of two or more
        # arguments, now in the DocumentFragment — and step 6 pre-inserts
        # before the viable next sibling. A single argument moves nothing, so
        # `x.replaceWith(x)` is a replace. "Replace" is the check that
        # disregards the child being replaced.
        moved_by_conversion = @__node__.parent != parent
        if moved_by_conversion
          ensure_parent_insertion_validity!(parent, args, viable_next)
        else
          ensure_parent_insertion_validity!(parent, args, @__node__, replacing: @__node__)
        end

        # Replace step 4's previousSibling is THIS node's previous sibling, and
        # the pre-insert path's is insert step 6's — both read before the
        # replacements are taken out of the DocumentFragment below.
        record_previous_replace = wrap_sibling(@__node__.previous_sibling)
        record_previous_insert = insertion_previous_sibling(parent, viable_next)
        record_next = wrap_sibling(viable_next)

        # WHATWG "replace" runs three removals/insertions in a fixed order:
        # adopt the replacement (step 6, which removes it from its old parent),
        # remove the old child (step 7), then insert (step 9) — and only the
        # insert carries the live-range offset shift, measured against the tree
        # both removals leave behind. The removal order is observable for
        # NodeIterator too: the old child's pre-removing steps run against a
        # tree that does not yet hold the replacements.
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        anchor = InsertionPoint.surviving_anchor(viable_next, parent)

        if moved_by_conversion
          # `@__node__` was itself an argument of a multi-argument call, so the
          # conversion moved it into the DocumentFragment; pre-insert the set
          # before the viable next sibling (step 6).
          @document.__internal_ranges_will_insert__(parent, anchor, nodes.size)
          insert_child_nodes(nodes, anchor, parent)
          notify_child_list(added: nodes, target: parent,
                            previous_sibling: record_previous_insert,
                            next_sibling: record_next)
        else
          # Replace step 7 removes the old child only when it still has a
          # parent; `x.replaceWith(x)` already lost it to step 6's adopt, and
          # then removedNodes stays empty.
          removed = []
          if @__node__.parent == parent
            @document.detach_node(@__node__)
            removed = [@__node__]
          end
          @document.__internal_ranges_will_insert__(parent, anchor, nodes.size)
          insert_child_nodes(nodes, anchor, parent)
          notify_child_list(added: nodes, removed: removed, target: parent,
                            previous_sibling: record_previous_replace,
                            next_sibling: record_next)
        end
        nil
      end

      # WebIDL nullable DOMString coercion (`DOMString?`): JS null and undefined
      # both become the null value, which callers treat as the empty string.
      def nullable_dom_string(value)
        return "" if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))

        value.to_s
      end

      # WebIDL check for `insertBefore(node, child)` from script: `child` is
      # required, though nullable, so a missing argument is a TypeError. (The
      # conversion of both arguments is #insert_before's own.) Now safe since
      # the seeded stubs report the correct arity (2), so `.length`-based WPT
      # helpers always pass the reference argument.
      def validate_insert_before_ref!(args)
        raise Bridge::TypeError, "insertBefore requires 2 arguments." if args.length < 2
      end

      private

      # WHATWG "pre-insert" step 1 for a mutation that targets this node's
      # PARENT (`before` / `after` / `replaceWith`). The constraints belong to
      # the parent, which may be a Document — whose step 6 forbids a Text child,
      # a second element and a misplaced doctype — so the check is dispatched on
      # the parent's wrapper rather than on self. It runs after the arguments
      # were converted into a node (InsertionPoint.convert_nodes_into_a_node), as
      # in the spec.
      def ensure_parent_insertion_validity!(parent_bn, args, ref_bn, replacing: nil)
        parent = @document.wrap_node(parent_bn)
        return unless parent.respond_to?(:__internal_ensure_insertion_validity__)

        parent.__internal_ensure_insertion_validity__(args, ref_bn, replacing: replacing)
      end

      # WHATWG `before` step 5: the reference child is the viable previous
      # sibling's next sibling, or the parent's first child when there is none.
      def reference_after(parent, viable_prev)
        viable_prev.nil? ? parent.children.first : viable_prev.next_sibling
      end

      # WHATWG pre-insert step 3: when the reference child IS one of the nodes
      # WHATWG insert steps 5 and 7, in spec order: shift the live-range offsets
      # that sit past `ref` in `parent`, THEN convert the arguments into backend
      # nodes (which detaches each from wherever it is now, running its own
      # removing steps). Doing it the other way round double-counts a boundary
      # that one of those removals has just moved onto `parent`.
      def convert_for_insert(args, parent, ref)
        @document.__internal_ranges_will_insert__(parent, ref, InsertionPoint.count(args))
        args.flat_map { |arg| detach_dom_nodes(arg) }
      end

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
          arg.__dommy_backend_node__ if arg.is_a?(Node)
        end
      end

      # Centralized MutationObserver childList notification. Defaults the
      # target to this node; beforebegin/afterend/replaceWith/outerHTML
      # callers pass the parent explicitly. The coordinator filters out
      # empty added/removed sets, so this is always safe to call.
      def notify_child_list(added: [], removed: [], target: @__node__,
                            previous_sibling: nil, next_sibling: nil)
        @document.notify_child_list_mutation(
          target_node: target,
          added_nodes: added,
          removed_nodes: removed,
          previous_sibling: previous_sibling,
          next_sibling: next_sibling
        )
      end

      # WHATWG insert step 9's record carries the insertion point: the reference
      # child as `nextSibling`, and step 6's `previousSibling` — the reference
      # child's previous sibling, or the parent's last child when appending,
      # BOTH measured before anything moves.
      def insertion_previous_sibling(parent, ref)
        wrap_sibling(InsertionPoint.previous_sibling(parent, ref))
      end

      def wrap_sibling(node)
        node && @document.wrap_node(node)
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
          source_document = value.document
          value.extract_children.map { |n| adopt_into_document(n, source_document) }
        when String
          [@document.create_text_node(value).__dommy_backend_node__]
        else
          node = value.__dommy_backend_node__ if value.is_a?(Node)
          return [] unless node

          # WHATWG pre-insert adopts the node into this node's document before
          # linking it. libxml2 reassigns ownership in place during add_child, so
          # the explicit adopt is a no-op move there; Makiri can't move a node
          # between document arenas, so a cross-document insert must adopt (an
          # imported copy) first. adopt_node reseats the Dommy wrapper onto the
          # adopted node, so JS identity (`parent.appendChild(x); x` ===
          # `parent.lastChild`) survives. Same-document: the wrapper's backend
          # node is unchanged, so this is identical to the previous behavior.
          detach_with_notify(node, value)
          [@document.adopt_node(value).__dommy_backend_node__]
        end
      end

      # Bring a raw backend node into this node's document (WHATWG adopt). A
      # no-op when already same-document; otherwise Backend.adopt — in place for
      # Nokogiri, an imported copy for Makiri (which can't move nodes between
      # arenas). Used for fragment children, which have no standalone wrapper to
      # reseat.
      def adopt_into_document(node, source_document = nil)
        target = @document.backend_doc
        return node if node.document == target

        @document.__internal_adopt_backend_node__(node, source_document)
      end

      # Detach a node from its current parent, queuing a childList removal
      # record on that old parent first (WHATWG "remove" runs before the
      # subsequent insert, so moving a node yields a removal record + an addition
      # record). Returns the raw node, ready to be re-linked.
      def detach_with_notify(node, wrapper = nil)
        # Document#remove_node_with_notify no-ops on a parentless node, runs the
        # pre-removing steps (live Range / NodeIterator) and captures the
        # position for the record before the unlink — a move must not skip them
        # just because the node is about to be re-inserted somewhere else. The
        # removal is the node's own document's (a node coming from another
        # document leaves that one, whose custom elements and observers see it).
        owner = wrapper.document if wrapper.respond_to?(:document)
        owner = @document unless owner.respond_to?(:remove_node_with_notify)
        owner.remove_node_with_notify(node)
        node
      end
    end
  end
end
