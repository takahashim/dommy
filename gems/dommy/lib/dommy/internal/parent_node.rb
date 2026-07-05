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
        coerce_node_argument!(child)
        ensure_pre_insertion_validity!(child, nil)
        nodes = detach_dom_nodes(child)
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
        child
      end

      # ParentNode#append — mixed Node/String args appended in order.
      def append(*args)
        validate_insertion_args!(args)
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
        nil
      end

      # ParentNode#prepend — insert before the current first child.
      def prepend(*args)
        validate_insertion_args!(args)
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        anchor = @__node__.children.first
        if anchor
          # Insert each node before the (fixed) original first child in order:
          # forward iteration keeps document order (n1, n2, … then the old first
          # child). Reversing here would emit them backwards.
          nodes.each { |n| anchor.add_previous_sibling(n) }
        else
          nodes.each { |n| @__node__.add_child(n) }
        end
        notify_child_list(added: nodes)
        nil
      end

      # ParentNode#replaceChildren — remove all existing children, then
      # append the new set. One mutation record carries both sides.
      def replace_children(*args)
        validate_insertion_args!(args)
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

      # Hierarchy guard hook. Default no-op (Fragment / ShadowRoot stay
      # permissive, matching current behavior). Element overrides this to
      # call its `check_hierarchy!`.
      def check_insertion!(_child)
        nil
      end

      # WebIDL coercion for an `appendChild`/`insertBefore`/`replaceChild`
      # argument typed `Node`: a null / undefined / non-Node value is a
      # TypeError before any DOM step runs.
      def coerce_node_argument!(value)
        return value if value.is_a?(Dommy::Node)

        raise Bridge::TypeError, "Argument is not a Node."
      end

      # WHATWG "ensure pre-insertion validity" for an element-like parent
      # (Element / DocumentFragment / ShadowRoot — never a Document, so the
      # document-only constraints in step 6 don't apply here). Steps run in
      # spec order so the observable error matches: ancestor check (2), the
      # reference child's parentage (3), the node's type (4), then the doctype
      # placement rule (5).
      def ensure_pre_insertion_validity!(node, child)
        # Step 2 — node must not be an inclusive ancestor of this parent.
        check_insertion!(node)

        # Step 3 — a non-null reference child must be a child of this parent.
        unless child.nil? || (defined?(Bridge::UNDEFINED) && child.equal?(Bridge::UNDEFINED))
          ref = child.respond_to?(:__dommy_backend_node__) ? child.__dommy_backend_node__ : nil
          unless ref && ref.parent == @__node__
            raise DOMException::NotFoundError, "The reference child is not a child of this node."
          end
        end

        # Step 4 — only an insertable node type may be inserted.
        unless insertable_child?(node)
          raise DOMException::HierarchyRequestError, "This node type cannot be inserted here."
        end

        # Step 5 — a doctype may only be a child of a document, never of an
        # element-like parent.
        return unless node.is_a?(Dommy::DocumentType)

        raise DOMException::HierarchyRequestError, "A doctype may only be a child of a document."
      end

      # Validate each Node argument of append / prepend / replaceChildren (which
      # also accept DOMStrings — those are always insertable as text, so skip
      # anything that isn't a Node).
      def validate_insertion_args!(args)
        args.each { |arg| ensure_pre_insertion_validity!(arg, nil) if arg.is_a?(Dommy::Node) }
      end

      # The node types that may be inserted under an element-like parent:
      # DocumentFragment, DocumentType, Element, and CharacterData (Text /
      # Comment / CDATASection / ProcessingInstruction — all CharacterDataNode
      # subclasses). A Document or Attr is not insertable.
      def insertable_child?(value)
        value.is_a?(Dommy::Element) || value.is_a?(Dommy::Fragment) ||
          value.is_a?(Dommy::CharacterDataNode) ||
          value.is_a?(Dommy::DocumentType)
      end
    end
  end
end
