# frozen_string_literal: true

module Dommy
  module Internal
    # The small facts every DOM insertion needs about where it is inserting, as
    # the WHATWG "insert" and "pre-insert" steps define them.
    #
    # They are here because three places perform insertions — ChildNode's
    # before/after/replaceWith, ParentNode's append/prepend/replaceChildren and
    # moveBefore, and Document's own child list — and each had grown its own
    # copy. Two of them had already drifted: the node count is spelled one way
    # in child_node.rb and another in document.rb.
    module InsertionPoint
      module_function

      # Insert step 1's count: how many nodes `args` will contribute once
      # converted. A DocumentFragment expands to its children, a String becomes
      # one Text node, and anything without a backing node contributes nothing.
      # Counted BEFORE any of them moves, because step 5 needs the count while
      # the fragment still holds its children.
      def count(args)
        args.sum do |arg|
          case arg
          when Fragment then arg.__dommy_backend_node__.children.to_a.size
          when String then 1
          else arg.respond_to?(:__dommy_backend_node__) ? 1 : 0
          end
        end
      end

      # Insert step 6's previousSibling: the reference child's previous sibling,
      # or the parent's last child when appending. Measured before anything
      # moves. Returns the backend node; the caller wraps it.
      def previous_sibling(parent, ref)
        ref ? ref.previous_sibling : parent.children.to_a.last
      end

      # Advance `ref` past any node that is itself being inserted: it is about
      # to move out of the way, so it cannot be the insertion point. This has to
      # happen before insert step 5, whose offset shift is measured against the
      # reference child's index — `x.before(x)` shifts boundaries past x's NEXT
      # sibling, not past x.
      def skip_args(ref, arg_nodes)
        ref = ref.next_sibling while ref && arg_nodes.any? { |node| node == ref }
        ref
      end

      # The same, walking backwards, for `before`'s viable previous sibling.
      def skip_args_backwards(ref, arg_nodes)
        ref = ref.previous_sibling while ref && arg_nodes.any? { |node| node == ref }
        ref
      end

      # An anchor is only an anchor while it is still a child of `parent`:
      # converting the arguments detaches each from wherever it is, which may
      # have been right here.
      def surviving_anchor(anchor, parent)
        anchor if anchor && anchor.parent == parent
      end
    end
  end
end
