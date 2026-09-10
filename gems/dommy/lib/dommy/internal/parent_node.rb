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
        # An append has a null reference child, so insert step 5 shifts nothing;
        # convert_for_insert still routes through it so every insertion site
        # reads the same.
        nodes = convert_for_insert([child], @__node__, nil)
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
        child
      end

      # ParentNode#append — mixed Node/String args appended in order.
      def append(*args)
        validate_insertion_args!(args)
        nodes = convert_for_insert(args, @__node__, nil)
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
        nil
      end

      # ParentNode#prepend — insert before the current first child.
      def prepend(*args)
        validate_insertion_args!(args)
        # The reference child is the CURRENT first child, and insert step 5 is
        # measured against it before the arguments are detached.
        anchor = @__node__.children.first
        nodes = convert_for_insert(args, @__node__, anchor)
        anchor = nil if anchor && anchor.parent != @__node__
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
        # "Replace all" removes every child first and then APPENDS, so there is
        # no reference child and insert step 5 shifts nothing.
        removed = detach_all_children
        nodes = convert_for_insert(args, @__node__, nil)
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
        # Removes every child, then APPENDS: no reference child, so insert
        # step 5 shifts nothing.
        removed = detach_all_children
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes, removed: removed)
        nil
      end

      # WHATWG "ensure pre-insertion validity" run on behalf of a ChildNode
      # mutation (`before` / `after` / `replaceWith`) whose insertion parent is
      # THIS node rather than the caller. The caller is a sibling (or the child
      # being replaced), so it cannot run the check itself: the constraints
      # belong to the parent, and a Document parent has stricter ones
      # (Document#__internal_ensure_insertion_validity__ overrides this).
      #
      # `ref_bn` is the raw backend reference child, nil when appending.
      # `replacing` is the child a `replaceWith` is standing in for; an
      # element-like parent has no rule that disregards it, so it is only
      # meaningful for a Document.
      def __internal_ensure_insertion_validity__(args, ref_bn, replacing: nil)
        _ = replacing
        ref = ref_bn && @document.wrap_node(ref_bn)
        args.each { |arg| ensure_pre_insertion_validity!(arg, ref) if arg.is_a?(Dommy::Node) }
        nil
      end

      # WHATWG ParentNode.moveBefore(node, child) — §4.2.6, and the "move"
      # primitive underneath it.
      #
      # A move is NOT remove + insert. It runs neither the removing steps nor
      # the insertion steps (so no disconnected/connected callbacks fire), it
      # never adopts — step 1 requires the same shadow-including root, so the
      # node document cannot change — and it carries its own validity checks
      # instead of "ensure pre-insertion validity". What it does share is the
      # live range pre-remove steps, the NodeIterator pre-remove steps and the
      # insert offset shift, so a live range or NodeIterator follows the node.
      #
      # Spec: https://dom.spec.whatwg.org/#dom-parentnode-movebefore
      def move_before(node, child = nil)
        coerce_node_argument!(node)
        bn = insertion_backend_node(node)
        ref_bn = insertion_backend_node(child)
        # moveBefore step 2: a reference child that IS the node moves out of the
        # way, so the reference becomes the node's next sibling.
        ref_bn = ref_bn.next_sibling if ref_bn && bn && ref_bn == bn
        move_node_before(node, bn, ref_bn)
        nil
      end

      # The "move" primitive, steps 1-24, for an element-like new parent.
      def move_node_before(node, bn, ref_bn)
        ensure_move_validity!(node, bn, ref_bn)

        old_parent = bn.parent
        old_previous = bn.previous_sibling
        old_next = bn.next_sibling
        # Steps 10-11 and 14. detach_node runs the live range and NodeIterator
        # pre-remove steps and then unlinks, without queuing a record — the move
        # queues its own pair at the end (steps 23-24).
        @document.detach_node(bn)

        ref_bn = nil if ref_bn && ref_bn.parent != @__node__
        # Step 16 — measured after the removal, which step 14 has already done.
        @document.__internal_ranges_will_insert__(@__node__, ref_bn, 1)
        new_previous = ref_bn ? ref_bn.previous_sibling : @__node__.children.last
        # Step 18.
        ref_bn ? ref_bn.add_previous_sibling(bn) : @__node__.add_child(bn)

        # Steps 23-24: one record for the old parent, one for the new.
        notify_move_records(bn, old_parent, old_previous, old_next, new_previous, ref_bn)
        node
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
        # WHATWG "replace" order: adopt the replacement (step 6, which removes it
        # from its old parent), then remove the old child (step 7), then insert
        # (step 9). Only the insert carries the live-range offset shift, and it
        # is measured against the tree both removals leave behind.
        nodes = detach_dom_nodes(new_child)

        removed = []
        if old_bn.parent == @__node__
          @document.detach_node(old_bn)
          removed = [old_bn]
        end

        anchor = nil if anchor && anchor.parent != @__node__
        @document.__internal_ranges_will_insert__(@__node__, anchor, nodes.size)
        insert_child_nodes(nodes, anchor, @__node__)
        notify_child_list(added: nodes, removed: removed)
        nil
      end

      # "Move" steps 1-6. Steps 5 and 6 only bind for a document new parent, so
      # they live in Document's own implementation.
      def ensure_move_validity!(node, bn, ref_bn)
        # Step 1 — the same shadow-including root, which is what makes a move a
        # move: the node document cannot change, so nothing is adopted.
        # `==` and not `equal?`: a backend may hand back a fresh Ruby object for
        # the same underlying node on every `parent` call.
        unless bn && shadow_including_root_of(bn) == shadow_including_root_of(@__node__)
          raise DOMException::HierarchyRequestError,
                "moveBefore requires the node and the new parent to share a root"
        end

        # Step 2 — no cycles.
        check_insertion!(node)

        # Step 3 — a non-null reference child must be a child of the new parent.
        if ref_bn && ref_bn.parent != @__node__
          raise DOMException::NotFoundError, "The reference child is not a child of this node."
        end

        # Step 4 — only an Element or a CharacterData node may be moved.
        return if node.is_a?(Dommy::Element) || node.is_a?(Dommy::CharacterDataNode)

        raise DOMException::HierarchyRequestError, "this node type cannot be moved"
      end

      # WHATWG "shadow-including root": the root, and if that is a shadow root,
      # the shadow-including root of its host.
      def shadow_including_root_of(backend_node)
        root = backend_node
        loop do
          root = root.parent while root.respond_to?(:parent) && root.parent
          shadow = @document.__internal_shadow_root_for_fragment__(root)
          host = shadow && shadow.host
          break unless host.respond_to?(:__dommy_backend_node__)

          root = host.__dommy_backend_node__
        end
        root
      end

      # "Move" steps 23-24: a removal record on the old parent and an addition
      # record on the new one, in that order.
      def notify_move_records(bn, old_parent, old_previous, old_next, new_previous, ref_bn)
        wrap = ->(n) { n && @document.wrap_node(n) }
        if old_parent
          @document.notify_child_list_mutation(
            target_node: old_parent, added_nodes: [], removed_nodes: [bn],
            previous_sibling: wrap.call(old_previous), next_sibling: wrap.call(old_next)
          )
        end
        @document.notify_child_list_mutation(
          target_node: @__node__, added_nodes: [bn], removed_nodes: [],
          previous_sibling: wrap.call(new_previous), next_sibling: wrap.call(ref_bn)
        )
      end

      # WHATWG "ensure pre-insertion validity" step 2 — node must not be a
      # host-including inclusive ancestor of the parent. It applies to every
      # parent kind the algorithm accepts (Element, DocumentFragment,
      # ShadowRoot); only Document is exempt, and a Document is never a
      # descendant of anything, so it has no such rule to run.
      def check_insertion!(child)
        check_hierarchy!(child)
      end

      # Raise HierarchyRequestError when the proposed insertion would produce a
      # cycle (inserting the parent itself, or one of its ancestors, into it).
      # Strings and other non-Nodes are always safe.
      def check_hierarchy!(child)
        node = insertion_backend_node(child)
        return if node.nil?
        return unless inclusive_ancestor_of_self?(node)

        raise(
          DOMException::HierarchyRequestError,
          "Cannot insert a node as a descendant of itself"
        )
      end

      # The backend node an insertion argument stands for, or nil for a value
      # that can never be an ancestor (a String, a non-Node).
      #
      # A Dommy::Document has no `__dommy_backend_node__` of its own, but WHATWG
      # counts it among its descendants' ancestors, so `el.insertBefore(document,
      # ref)` violates step 2 (a cycle) and must be a HierarchyRequestError
      # before step 3 gets to complain that `ref` is not a child.
      def insertion_backend_node(child)
        return child.backend_doc if child.is_a?(Dommy::Document)
        return nil unless child.respond_to?(:__dommy_backend_node__)

        node = child.__dommy_backend_node__
        node.is_a?(Backend.node_class) ? node : nil
      end

      # Whether `node` is this node or one of its ancestors.
      #
      # Walks `parent` upward rather than asking the backend for `ancestors`:
      # Makiri omits a DocumentFragment parent from `ancestors`, so a fragment
      # would never appear to contain its own children. The walk also runs past
      # the document element to the document itself, which
      # NodeTraversal.each_ancestor deliberately stops short of.
      def inclusive_ancestor_of_self?(node)
        cur = @__node__
        while cur
          return true if cur == node

          cur = cur.respond_to?(:parent) ? cur.parent : nil
        end
        false
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
