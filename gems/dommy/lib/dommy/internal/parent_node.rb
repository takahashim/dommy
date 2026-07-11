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
      # Argument coercion (`detach_dom_nodes`), childList notification, and the
      # ChildNode `before`/`after`/`replaceWith` surface all live in ChildNode,
      # shared with the leaf CharacterData nodes.
      include ChildNode

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

      # Node#normalize — merge each run of adjacent exclusive Text descendants
      # into its first node (preserving that node's identity, so a JS reference
      # to it survives) and drop empty Text nodes. Recurses the whole subtree,
      # so it works for Element, DocumentFragment, and ShadowRoot alike.
      def normalize
        text_nodes = []
        @__node__.traverse { |node| text_nodes << node if node.respond_to?(:text?) && node.text? }

        text_nodes.each do |node|
          next unless node.parent # already removed as part of an earlier run

          if node.content.to_s.empty?
            @document.remove_node_with_notify(node)
            next
          end

          merged = []
          sib = node.next
          while sib.respond_to?(:text?) && sib.text?
            merged << sib
            sib = sib.next
          end
          next if merged.empty?

          old = node.content.to_s
          node.content = old + merged.map { |m| m.content.to_s }.join
          @document.notify_character_data_mutation(target_node: node, old_value: old)
          merged.each { |m| @document.remove_node_with_notify(m) }
        end

        nil
      end

      private

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
