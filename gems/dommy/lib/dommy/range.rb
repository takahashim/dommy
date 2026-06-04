# frozen_string_literal: true

module Dommy
  # `Range` — a span between two boundary points in the DOM, used by
  # text-editing / highlighting / selection logic.
  #
  # Dommy has no layout, so methods that return pixel rectangles
  # (`getBoundingClientRect`, `getClientRects`) return zeroed values.
  # All non-layout operations (selectNode, extractContents,
  # cloneContents, surroundContents, deleteContents, toString,
  # collapse, compareBoundaryPoints, intersectsNode, containsNode)
  # work against the actual DOM tree.
  #
  # Spec: https://dom.spec.whatwg.org/#interface-range
  class Range
    # compareBoundaryPoints `how` constants.
    START_TO_START = 0
    START_TO_END = 1
    END_TO_END = 2
    END_TO_START = 3

    attr_reader :start_container, :start_offset, :end_container, :end_offset

    def initialize(document)
      @document = document
      # Default: collapsed at start of the document
      @start_container = document
      @start_offset = 0
      @end_container = document
      @end_offset = 0
    end

    def collapsed?
      @start_container.equal?(@end_container) && @start_offset == @end_offset
    end

    alias collapsed collapsed?

    def common_ancestor_container
      # Find the lowest (deepest) common ancestor of start_container
      # and end_container. Walk from start_container up and return the
      # first node also present in end_container's ancestor chain.
      starts = ancestor_chain(@start_container)
      ends_set = ancestor_chain(@end_container)
      starts.find { |a| ends_set.any? { |e| e.equal?(a) } } || @document
    end

    # --- Boundary setters --------------------------------------------

    def set_start(node, offset)
      @start_container = node
      @start_offset = offset.to_i
      collapse_to_start if compare_points(@start_container, @start_offset, @end_container, @end_offset) > 0
      nil
    end

    def set_end(node, offset)
      @end_container = node
      @end_offset = offset.to_i
      collapse_to_end if compare_points(@start_container, @start_offset, @end_container, @end_offset) > 0
      nil
    end

    def set_start_before(node)
      parent = parent_of(node)
      set_start(parent, child_index_of(parent, node))
    end

    def set_start_after(node)
      parent = parent_of(node)
      set_start(parent, child_index_of(parent, node) + 1)
    end

    def set_end_before(node)
      parent = parent_of(node)
      set_end(parent, child_index_of(parent, node))
    end

    def set_end_after(node)
      parent = parent_of(node)
      set_end(parent, child_index_of(parent, node) + 1)
    end

    def collapse(to_start = false)
      if to_start
        @end_container = @start_container
        @end_offset = @start_offset
      else
        @start_container = @end_container
        @start_offset = @end_offset
      end

      nil
    end

    def select_node(node)
      parent = parent_of(node)
      idx = child_index_of(parent, node)
      @start_container = parent
      @start_offset = idx
      @end_container = parent
      @end_offset = idx + 1
      nil
    end

    def select_node_contents(node)
      @start_container = node
      @start_offset = 0
      @end_container = node
      @end_offset = length_of(node)
      nil
    end

    # --- Content extraction ----------------------------------------

    def to_s
      Internal::RangeTextSerializer.new(self).serialize
    end

    # cloneContents — returns a DocumentFragment with a deep clone of
    # the range contents. Range is left unchanged.
    def clone_contents
      fragment = @document.create_document_fragment
      contents = collect_nodes_in_range
      contents.each do |node|
        clone = clone_wrapped(node)
        fragment.append_child(clone) if clone
      end

      fragment
    end

    # extractContents — like cloneContents but also removes the
    # extracted nodes from the document.
    def extract_contents
      fragment = clone_contents
      delete_contents
      fragment
    end

    # WHATWG Range.deleteContents. Removes the fully-contained nodes (childList
    # records) and trims the partially-contained boundary CharacterData nodes
    # (characterData records via `data=`), rather than removing boundary text
    # nodes whole — so a deletion like `"abc"[1]…"def"[1]` leaves `"a"…"ef"`.
    def delete_contents
      return nil if collapsed?

      sc = @start_container
      so = @start_offset
      ec = @end_container
      eo = @end_offset

      # Both boundaries in the same text node: just delete the substring.
      if sc.equal?(ec) && text_node?(sc)
        d = sc.data.to_s
        sc.data = d[0, so].to_s + (d[eo..] || "")
        return nil
      end

      to_remove = nodes_to_remove
      new_node, new_offset = deletion_collapse_point(sc, so, ec, eo)

      # Trim the start boundary text node's tail, remove the contained nodes,
      # then trim the end boundary text node's head (order matters for records).
      sc.data = sc.data.to_s[0, so].to_s if text_node?(sc)
      to_remove.each do |node|
        if node.respond_to?(:__dommy_backend_node__)
          @document.remove_node_with_notify(node.__dommy_backend_node__)
        elsif node.respond_to?(:remove)
          node.remove
        end
      end
      ec.data = (ec.data.to_s[eo..] || "") if text_node?(ec)

      @start_container = @end_container = new_node
      @start_offset = @end_offset = new_offset
      nil
    end

    # Top-level nodes fully contained in the range (their parent isn't), removed
    # whole. Deeper contained nodes go with their removed ancestor.
    def nodes_to_remove
      ancestor = common_ancestor_container
      return [] unless ancestor.respond_to?(:child_nodes)

      ancestor.child_nodes.to_a.select { |child| node_fully_contained?(child) }
    end

    # A node is contained in the range when its start position is at or after the
    # range start and its end position is at or before the range end.
    def node_fully_contained?(node)
      parent = parent_of(node)
      return false unless parent

      idx = child_index_of(parent, node)
      compare_points(parent, idx, @start_container, @start_offset) >= 0 &&
        compare_points(parent, idx + 1, @end_container, @end_offset) <= 0
    end

    # The (node, offset) the range collapses to after deletion (WHATWG step 5):
    # the start boundary if it contains the end, else the start's highest
    # ancestor that doesn't contain the end, positioned just after it.
    def deletion_collapse_point(sc, so, ec, eo)
      return [sc, so] if inclusive_ancestor?(sc, ec)

      ref = sc
      ref = parent_of(ref) while (p = parent_of(ref)) && !inclusive_ancestor?(p, ec)
      parent = parent_of(ref)
      [parent, child_index_of(parent, ref) + 1]
    end

    def inclusive_ancestor?(maybe_ancestor, node)
      current = node
      while current
        return true if current.equal?(maybe_ancestor)

        current = parent_of(current)
      end
      false
    end

    # surroundContents(newParent) — wraps the range contents in
    # newParent (which must be an element).
    def surround_contents(new_parent)
      contents = extract_contents
      new_parent.append_child(contents)
      # Insert new_parent at the (now-collapsed) range start.
      insert_node(new_parent)
      select_node(new_parent)
      nil
    end

    def insert_node(node)
      # Insert at the range start. For text-node containers we split;
      # for element containers we insert at child index.
      sc = @start_container
      if text_node?(sc)
        # Splitting is out of spec-perfect scope; insert before/after
        # the text node based on offset.
        parent = parent_of(sc)
        idx = child_index_of(parent, sc)
        idx += 1 if @start_offset >= length_of(sc)
        insert_into_parent_at(parent, idx, node)
      else
        insert_into_parent_at(sc, @start_offset, node)
      end

      nil
    end

    # --- Ordering / containment ------------------------------------

    def compare_boundary_points(how, other)
      # `how` must be one of the four named constants, else NotSupportedError.
      unless [START_TO_START, START_TO_END, END_TO_END, END_TO_START].include?(how)
        raise DOMException::NotSupportedError, "invalid comparison type: #{how}"
      end
      # The two ranges must share a root.
      unless same_root?(other.start_container)
        raise DOMException::WrongDocumentError, "the two Ranges are in different trees"
      end

      case how
      when START_TO_START
        compare_points(@start_container, @start_offset, other.start_container, other.start_offset)
      when START_TO_END
        compare_points(@end_container, @end_offset, other.start_container, other.start_offset)
      when END_TO_END
        compare_points(@end_container, @end_offset, other.end_container, other.end_offset)
      when END_TO_START
        compare_points(@start_container, @start_offset, other.end_container, other.end_offset)
      end
    end

    def intersects_node(node)
      # Range and node intersect iff node's "position relative to range"
      # is not entirely before or entirely after.
      return false if before?(node)
      return false if after?(node)

      true
    end

    # WHATWG Range.comparePoint(node, offset): -1 if (node, offset) is before the
    # range, 0 if inside, 1 if after. offset is a WebIDL unsigned long (so -1
    # wraps to a huge value > length → IndexSizeError).
    def compare_point(node, offset)
      off = unsigned_long(offset)
      raise DOMException::WrongDocumentError, "node is in a different tree" unless same_root?(node)
      raise DOMException::InvalidNodeTypeError, "node is a doctype" if doctype?(node)
      raise DOMException::IndexSizeError, "offset is greater than node length" if off > length_of(node)

      return -1 if compare_points(node, off, @start_container, @start_offset) < 0
      return 1 if compare_points(node, off, @end_container, @end_offset) > 0

      0
    end

    # WHATWG Range.isPointInRange(node, offset): true iff the point lies within
    # the range (inclusive). A different root returns false (no throw).
    def is_point_in_range(node, offset)
      return false unless same_root?(node)

      off = unsigned_long(offset)
      raise DOMException::InvalidNodeTypeError, "node is a doctype" if doctype?(node)
      raise DOMException::IndexSizeError, "offset is greater than node length" if off > length_of(node)

      compare_points(node, off, @start_container, @start_offset) >= 0 &&
        compare_points(node, off, @end_container, @end_offset) <= 0
    end

    def contains_node(node, partial = false)
      if partial
        intersects_node(node)
      else
        # node must be wholly inside the range
        !before?(node) && !after?(node) && fully_inside?(node)
      end
    end

    # --- Cloning ---------------------------------------------------

    def clone_range
      r = Range.new(@document)
      r.set_start(@start_container, @start_offset)
      r.set_end(@end_container, @end_offset)
      r
    end

    # --- Layout stubs ----------------------------------------------
    # No layout engine; return zeroed rects so callers don't crash.

    def get_bounding_client_rect
      DOMRect.new(x: 0, y: 0, width: 0, height: 0)
    end

    def get_client_rects
      []
    end

    # --- JS bridge -------------------------------------------------

    def __js_get__(key)
      case key
      when "startContainer"
        @start_container
      when "startOffset"
        @start_offset
      when "endContainer"
        @end_container
      when "endOffset"
        @end_offset
      when "collapsed"
        collapsed?
      when "commonAncestorContainer"
        common_ancestor_container
      end
    end

    include Bridge::Methods
    js_methods %w[
      setStart setEnd setStartBefore setStartAfter setEndBefore setEndAfter collapse selectNode
      selectNodeContents toString cloneContents extractContents deleteContents surroundContents
      insertNode compareBoundaryPoints intersectsNode containsNode cloneRange detach
      comparePoint isPointInRange getBoundingClientRect getClientRects
    ]
    def __js_call__(method, args)
      case method
      when "setStart"
        set_start(args[0], args[1])
      when "setEnd"
        set_end(args[0], args[1])
      when "setStartBefore"
        set_start_before(args[0])
      when "setStartAfter"
        set_start_after(args[0])
      when "setEndBefore"
        set_end_before(args[0])
      when "setEndAfter"
        set_end_after(args[0])
      when "collapse"
        collapse(args[0])
      when "selectNode"
        select_node(args[0])
      when "selectNodeContents"
        select_node_contents(args[0])
      when "toString"
        to_s
      when "cloneContents"
        clone_contents
      when "extractContents"
        extract_contents
      when "deleteContents"
        delete_contents
      when "surroundContents"
        surround_contents(args[0])
      when "insertNode"
        insert_node(args[0])
      when "compareBoundaryPoints"
        compare_boundary_points(args[0], args[1])
      when "intersectsNode"
        intersects_node(args[0])
      when "comparePoint"
        compare_point(args[0], args[1])
      when "isPointInRange"
        is_point_in_range(args[0], args[1])
      when "containsNode"
        contains_node(args[0], args[1])
      when "cloneRange"
        clone_range
      when "detach"
        nil
      when "getBoundingClientRect"
        get_bounding_client_rect
      when "getClientRects"
        get_client_rects
      end
    end

    private

    def collapse_to_start
      @end_container = @start_container
      @end_offset = @start_offset
    end

    def collapse_to_end
      @start_container = @end_container
      @start_offset = @end_offset
    end

    def text_node?(node)
      node.respond_to?(:node_type) && node.node_type == 3
    end

    def length_of(node)
      if text_node?(node)
        node.data.to_s.length
      elsif node.respond_to?(:child_nodes)
        node.child_nodes.length
      else
        0
      end
    end

    # WebIDL unsigned long: wrap modulo 2^32 (so -1 → 4294967295).
    def unsigned_long(value)
      value.to_i % (2**32)
    end

    # Two nodes share a root iff their topmost ancestors are the same node.
    def same_root?(node)
      ancestor_chain(node).last.equal?(ancestor_chain(@start_container).last)
    end

    def doctype?(node)
      nt = if node.respond_to?(:node_type) then node.node_type
           elsif node.respond_to?(:__js_get__) then node.__js_get__("nodeType")
           end
      nt == 10
    end

    def insert_into_parent_at(parent, idx, node)
      children = parent.respond_to?(:child_nodes) ? parent.child_nodes.to_a : []
      if idx >= children.length
        parent.append_child(node) if parent.respond_to?(:append_child)
      else
        anchor = children[idx]
        if anchor.respond_to?(:before)
          anchor.before(node)
        elsif parent.respond_to?(:insert_before)
          parent.insert_before(node, anchor)
        else
          parent.append_child(node) if parent.respond_to?(:append_child)
        end
      end
    end

    def clone_wrapped(node)
      return nil unless node.respond_to?(:__js_call__)

      node.__js_call__("cloneNode", [true])
    end

    # Collect top-level nodes contained in the range. Simple
    # approximation that walks child_nodes of common ancestor and
    # picks nodes fully inside the range.
    def collect_nodes_in_range
      ancestor = common_ancestor_container
      return [] unless ancestor.respond_to?(:child_nodes)

      ancestor.child_nodes.to_a.select { |child| fully_inside?(child) }
    end

    def before?(node)
      # node is entirely before the range start
      compare_node_to_point(node, true, @start_container, @start_offset) < 0 &&
        compare_node_to_point(node, false, @start_container, @start_offset) <= 0
    end

    def after?(node)
      # node is entirely after the range end
      compare_node_to_point(node, true, @end_container, @end_offset) >= 0
    end

    def fully_inside?(node)
      # node is entirely inside [start, end]
      !before?(node) && !after?(node)
    end

    # Compare a (node-edge) to a (container, offset) point.
    # `is_start` selects the leading edge of the node when true,
    # trailing edge when false. Result mimics compare_points: -1/0/+1.
    def compare_node_to_point(node, is_start, container, offset)
      parent = parent_of(node)
      return 0 if parent.nil?

      node_offset = child_index_of(parent, node) + (is_start ? 0 : 1)
      compare_points(parent, node_offset, container, offset)
    end

    # --- Tree-ordering helpers --------------------------------------

    def parent_of(node)
      node.respond_to?(:parent_node) ? node.parent_node : nil
    end

    def child_index_of(parent, node)
      return 0 unless parent.respond_to?(:child_nodes)

      parent.child_nodes.to_a.index { |n| n.equal?(node) } || 0
    end

    def ancestor_chain(node)
      chain = [node]
      current = node
      while (p = parent_of(current))
        chain << p
        current = p
      end

      chain
    end

    # Compare (a_container, a_offset) vs (b_container, b_offset).
    # Returns -1 if A precedes B, +1 if A follows, 0 if equal.
    #
    # Dispatches on the three topological cases:
    #   1. both points are inside the same container (offset compare)
    #   2. one container is an ancestor of the other (subtree case)
    #   3. neither contains the other → use lowest common ancestor
    def compare_points(a_container, a_offset, b_container, b_offset)
      return a_offset <=> b_offset if a_container.equal?(b_container)

      a_chain = ancestor_chain(a_container)
      b_chain = ancestor_chain(b_container)

      if (b_branch = branch_under(b_chain, a_container))
        return compare_offset_to_branch(a_offset, a_container, b_branch, ahead: -1)
      end

      if (a_branch = branch_under(a_chain, b_container))
        return compare_branch_to_offset(b_offset, b_container, a_branch, behind: 1)
      end

      compare_via_lca(a_chain, b_chain)
    end

    # The direct child of `container` that lies on `chain`'s path,
    # or nil if `container` isn't on the chain.
    def branch_under(chain, container)
      chain.find { |n| parent_of(n)&.equal?(container) }
    end

    # Case 2a: a_container is an ancestor of b_container. b sits *inside* the
    # child of a_container at index b_idx (so its exact offset is irrelevant):
    # if that index is before a_offset, a comes after b; otherwise a precedes b
    # (WHATWG boundary-point position, ancestor case).
    def compare_offset_to_branch(a_offset, a_container, b_branch, ahead:)
      b_idx = child_index_of(a_container, b_branch)
      b_idx < a_offset ? 1 : ahead
    end

    # Case 2b: b_container is an ancestor of a_container.
    def compare_branch_to_offset(b_offset, b_container, a_branch, behind:)
      a_idx = child_index_of(b_container, a_branch)
      return a_idx <=> b_offset if b_offset > a_idx

      behind
    end

    # Case 3: disjoint subtrees — compare branch indices under the
    # lowest common ancestor.
    def compare_via_lca(a_chain, b_chain)
      lca = a_chain.find { |n| b_chain.any? { |b| b.equal?(n) } }
      return 0 unless lca

      a_branch = a_chain.find { |n| parent_of(n)&.equal?(lca) }
      b_branch = b_chain.find { |n| parent_of(n)&.equal?(lca) }
      return 0 unless a_branch && b_branch

      child_index_of(lca, a_branch) <=> child_index_of(lca, b_branch)
    end
  end

  # `Selection` — represents user-selected ranges in the document.
  # Always at most one range in Dommy's stub implementation
  # (matching common browser behavior).
  #
  # Spec: https://www.w3.org/TR/selection-api/
  class Selection
    def initialize(document)
      @document = document
      @ranges = []
    end

    def range_count
      @ranges.length
    end

    def get_range_at(index)
      @ranges[index.to_i]
    end

    def add_range(range)
      # Spec says modern browsers ignore add_range if a range already
      # exists; we keep the behavior simple and replace.
      @ranges = [range]
      nil
    end

    def remove_range(range)
      @ranges.delete(range)
      nil
    end

    def remove_all_ranges
      @ranges.clear
      nil
    end

    def empty
      remove_all_ranges
    end

    def collapse(node, offset = 0)
      range = Range.new(@document)
      range.set_start(node, offset)
      range.set_end(node, offset)
      add_range(range)
      nil
    end

    def select_all_children(node)
      range = Range.new(@document)
      range.select_node_contents(node)
      add_range(range)
      nil
    end

    def to_s
      @ranges.map(&:to_s).join
    end

    def anchor_node
      @ranges.first&.start_container
    end

    def anchor_offset
      @ranges.first&.start_offset || 0
    end

    def focus_node
      @ranges.first&.end_container
    end

    def focus_offset
      @ranges.first&.end_offset || 0
    end

    def is_collapsed
      @ranges.empty? || @ranges.first.collapsed?
    end

    alias isCollapsed is_collapsed

    def __js_get__(key)
      case key
      when "rangeCount"
        range_count
      when "anchorNode"
        anchor_node
      when "anchorOffset"
        anchor_offset
      when "focusNode"
        focus_node
      when "focusOffset"
        focus_offset
      when "isCollapsed"
        is_collapsed
      when "type"
        is_collapsed ? "Caret" : "Range"
      end
    end

    include Bridge::Methods
    js_methods %w[
      getRangeAt addRange removeRange removeAllRanges empty collapse selectAllChildren toString
    ]
    def __js_call__(method, args)
      case method
      when "getRangeAt"
        get_range_at(args[0])
      when "addRange"
        add_range(args[0])
      when "removeRange"
        remove_range(args[0])
      when "removeAllRanges"
        remove_all_ranges
      when "empty"
        empty
      when "collapse"
        collapse(args[0], args[1] || 0)
      when "selectAllChildren"
        select_all_children(args[0])
      when "toString"
        to_s
      end
    end
  end
end
