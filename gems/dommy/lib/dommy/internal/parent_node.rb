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
        removed = detach_all_children
        nodes = args.flat_map { |arg| detach_dom_nodes(arg) }
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes, removed: removed)
        nil
      end

      # WHATWG "replace all with node within a parent": remove every child in
      # tree order (through the shared removal primitive, so each one runs the
      # pre-removing steps), insert the new nodes, and queue ONE childList
      # record carrying both sides. Backs textContent=, a ShadowRoot's
      # innerHTML=, and a <template>'s content replacement.
      #
      # `__internal_` because collaborators outside the node classes call it
      # (TemplateContentRegistry); within a node, prefer `string_replace_all`.
      #
      # Spec: https://dom.spec.whatwg.org/#concept-node-replace-all
      def __internal_replace_all__(nodes)
        removed = detach_all_children
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes, removed: removed)
        nil
      end

      # Node#normalize — merge each run of adjacent exclusive Text descendants
      # into its first node (preserving that node's identity, so a JS reference
      # to it survives) and drop empty Text nodes. Recurses the whole subtree,
      # so it works for Element, DocumentFragment, and ShadowRoot alike.
      #
      # A run is merged one sibling at a time: append the sibling's data to the
      # survivor (a characterData record), hand its live range boundaries over,
      # remove it (a childList record), then the next. Read literally, the spec
      # concatenates every sibling's data first (steps 3-4, one "replace data")
      # and removes them afterwards (step 7), which would queue ONE
      # characterData record per run. Every shipping engine merges pairwise
      # instead — Blink, WebCore and Gecko all answer [characterData, childList,
      # characterData, childList, …] for a run of four text nodes, confirmed by
      # running the same script in Chromium 141, WebKitGTK 2.52.6 and Firefox —
      # and the WPT suite fixes only the childList side, so the records follow
      # the engines. The tree and every live range boundary end up exactly where
      # the spec's steps put them: a boundary in a later sibling (or on the
      # parent, pointing at one) is shifted down by each earlier removal and
      # then handed over at the survivor's length of that moment, which is the
      # same offset the batch steps compute up front.
      # https://github.com/takahashim/dommy/issues/24
      def normalize
        text_nodes = []
        @__node__.traverse { |node| text_nodes << node if node.respond_to?(:text?) && node.text? }

        text_nodes.each do |node|
          next unless node.parent # already removed as part of an earlier run

          if node.content.to_s.empty?
            @document.remove_node_with_notify(node)
            next
          end

          sib = node.next
          while sib.respond_to?(:text?) && sib.text?
            following = sib.next
            data = sib.content.to_s
            # The offset the sibling's data lands at inside the survivor — the
            # length of what it already holds, measured before the append.
            length = @document.wrap_node(node).length
            # An empty sibling has nothing to append: the engines skip the data
            # step for it (Gecko checks the length, Blink and WebCore behave the
            # same), so it is removed without a characterData record. Its range
            # boundaries still move to the survivor's join.
            unless data.empty?
              old = node.content.to_s
              node.content = old + data
              @document.notify_character_data_mutation(target_node: node, old_value: old)
            end
            # WHATWG normalize() step 6: the merged-away sibling hands its live
            # range boundaries to the survivor at that offset BEFORE it is
            # removed, or the plain removing steps would strand them on the
            # parent.
            @document.__internal_ranges_normalize_merge__(node, sib, length)
            @document.remove_node_with_notify(sib)
            sib = following
          end
        end

        nil
      end

      private

      # Steps 3-4 of "replace all": detach every child in tree order, returning
      # them so the caller can name them in the single record that covers the
      # whole operation.
      def detach_all_children
        removed = @__node__.children.to_a
        removed.each { |n| @document.detach_node(n) }
        removed
      end

      # WHATWG "string replace all" — the textContent setter for Element,
      # DocumentFragment and ShadowRoot alike. The empty string (and a null /
      # undefined, which coerce to it) leaves the parent with NO children rather
      # than an empty Text node.
      #
      # Spec: https://dom.spec.whatwg.org/#string-replace-all
      def string_replace_all(value)
        str = nullable_dom_string(value)
        nodes = str.empty? ? [] : [@document.create_text_node(str).__dommy_backend_node__]
        __internal_replace_all__(nodes)
      end

      # WHATWG "replace a child with node within a parent", shared by Element,
      # DocumentFragment and ShadowRoot. `old_bn` must already be validated as a
      # child of this node; each caller keeps its own WebIDL / hierarchy checks.
      #
      # The old child is REMOVED BEFORE the replacements are inserted. That
      # order is observable: the pre-removing steps run against a tree that does
      # not yet hold the new nodes, so a NodeIterator anchored inside the old
      # child falls back to this parent rather than to a node that was not there
      # when the removal happened.
      #
      # Spec: https://dom.spec.whatwg.org/#concept-node-replace
      def replace_child_within(new_child, old_bn)
        # Capture the insertion point (old's next sibling) before converting the
        # new child, which may itself be old (replaceChild(x, x)) or old's
        # sibling. WHATWG: when that reference child IS the node being inserted,
        # advance it to the node's next sibling so the node lands in old's slot
        # rather than being appended.
        anchor = old_bn.next_sibling
        new_bn = new_child.respond_to?(:__dommy_backend_node__) ? new_child.__dommy_backend_node__ : nil
        anchor = anchor.next_sibling if anchor && new_bn && anchor == new_bn
        nodes = detach_dom_nodes(new_child)
        anchor = nil if anchor && anchor.parent != @__node__

        # detach_dom_nodes already removed old when new_child === old_child; only
        # detach (and record the removal) when old is still attached.
        removed = []
        if old_bn.parent == @__node__
          @document.detach_node(old_bn)
          removed = [old_bn]
        end

        insert_child_nodes(nodes, anchor, @__node__)
        notify_child_list(added: nodes, removed: removed)
        nil
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
