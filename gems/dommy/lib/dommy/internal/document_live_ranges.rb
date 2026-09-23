# frozen_string_literal: true

module Dommy
  module Internal
    # The live Ranges registered against this document, and the offset shifts a
    # mutation owes them (DOM §5.5's "live range" steps).
    #
    # Document's, but its own subject: the class had thirty-one __internal_*
    # seams through which every collaborator reached its state.
    module DocumentLiveRanges
      def __internal_register_range__(range)
        @live_ranges ||= ObjectSpace::WeakMap.new
        @live_ranges[range] = true
        nil
      end

      def __internal_each_live_range__
        return if @live_ranges.nil? || @live_ranges.size.zero?
  
        @live_ranges.each_key { |range| yield range }
      end

      def live_ranges?
        !@live_ranges.nil? && @live_ranges.size.positive?
      end

      # WHATWG normalize() steps 6.1-6.4. `current` is a contiguous exclusive Text
      # sibling whose data has just been appended to `node` at `length`; its own
      # boundaries — and a parent-anchored boundary pointing AT it — follow the
      # data into the merged node. Run for every merged sibling before any of them
      # is removed, so the indices still describe the pre-removal tree.
      def __internal_ranges_normalize_merge__(node, current, length)
        return unless live_ranges?
  
        merged_into = wrap_node(node)
        current_wrapper = wrap_node(current)
        parent = current.parent && wrap_node(current.parent)
        index = parent && child_index_of_wrapper(parent, current_wrapper)
        __internal_each_live_range__ do |range|
          range.__internal_apply_normalize_merge__(merged_into, current_wrapper, length, parent, index)
        end
      end

      def __internal_ranges_split_text__(node, offset, new_node)
        return unless live_ranges?
  
        parent = node.parent_node
        # Only the parent-anchored rule needs an index, so resolve one lazily.
        index =
          if parent && live_ranges_where { |r| r.__internal_anchored_at__(parent) }.any?
            child_index_of_wrapper(parent, node)
          end
        __internal_each_live_range__ { |r| r.__internal_apply_split__(node, offset, new_node, parent, index) }
      end

      # WHATWG "insert a node into a parent before a child", step 5 — the
      # live-range offset shift.
      #
      # It runs BEFORE step 7 adopts each node (which removes it from wherever it
      # is now), so `child`'s index, and every boundary it shifts, are measured
      # against the tree as it stands before the insertion begins. Running it
      # afterwards double-counts a boundary that one of those removals has just
      # moved onto `parent`: `parent.insertBefore(second, first)` with a range
      # inside `second` leaves that boundary at `(parent, 1)` per spec, but at
      # `(parent, 2)` if the shift is applied after the move.
      #
      # Appending (a null `child`) shifts nothing: a boundary at the parent's end
      # stays before the new nodes.
      def __internal_ranges_will_insert__(parent_backend_node, ref_backend_node, count)
        return if ref_backend_node.nil? || count.zero?
        return unless live_ranges?
  
        parent_wrapper = wrap_node(parent_backend_node)
        return unless parent_wrapper.respond_to?(:child_nodes)
  
        affected = live_ranges_where { |r| r.__internal_anchored_at__(parent_wrapper) }
        return if affected.empty?
  
        index = child_index_of_wrapper(parent_wrapper, wrap_node(ref_backend_node))
        return unless index
  
        affected.each { |r| r.__internal_apply_insert__(parent_wrapper, index, count) }
      end

      def live_ranges_where
        out = []
        __internal_each_live_range__ { |r| out << r if yield(r) }
        out
      end

      def child_index_of_wrapper(parent_wrapper, child_wrapper)
        return nil unless parent_wrapper.respond_to?(:child_nodes)
  
        parent_wrapper.child_nodes.to_a.index { |c| c.equal?(child_wrapper) }
      end
    end
  end
end
