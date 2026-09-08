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
      # Ranges are LIVE: the document tracks them so every mutation that can
      # shift a boundary point gets a chance to move it (see the
      # `__internal_apply_*` steps below).
      document.__internal_register_range__(self)
    end

    # --- Live range mutation rules -----------------------------------
    # WHATWG spreads these across the mutation algorithms ("insert", "remove",
    # "replace data", "split"). A boundary point has to follow the tree so the
    # range keeps designating the same content: text inserted before it shifts
    # it along, text deleted under it clamps it, and a removed node hands its
    # boundaries to the position it vacated.

    # "Replace data" steps 8-11. `count` characters at `offset` became
    # `new_length` characters.
    def __internal_apply_replace_data__(node, offset, count, new_length)
      delta = new_length - count
      limit = offset + count
      # Each boundary is rewritten from its ORIGINAL value: one past the replaced
      # run slides by the length difference, one inside it clamps to the run's
      # start, and one before it is untouched. The two rules are mutually
      # exclusive on the original offset, so they must be an if/elsif — sliding
      # first and then re-testing would clamp a boundary already moved correctly.
      if @start_container.equal?(node)
        if @start_offset > limit
          @start_offset += delta
        elsif @start_offset > offset
          @start_offset = offset
        end
      end
      if @end_container.equal?(node)
        if @end_offset > limit
          @end_offset += delta
        elsif @end_offset > offset
          @end_offset = offset
        end
      end
      nil
    end

    # "Split" steps 7.2-7.5: the tail of the split moves to `new_node`, and a
    # boundary sitting right where the new node lands shifts past it.
    def __internal_apply_split__(node, offset, new_node, parent, index)
      if @start_container.equal?(node) && @start_offset > offset
        @start_container = new_node
        @start_offset -= offset
      end
      if @end_container.equal?(node) && @end_offset > offset
        @end_container = new_node
        @end_offset -= offset
      end
      return nil unless parent

      @start_offset += 1 if @start_container.equal?(parent) && @start_offset == index + 1
      @end_offset += 1 if @end_container.equal?(parent) && @end_offset == index + 1
      nil
    end

    # normalize() steps 6.1-6.4: `current`'s data has been appended to `node` at
    # offset `length`, so a boundary inside `current` slides into `node`, and a
    # parent-anchored boundary sitting exactly at `current` lands at the join.
    def __internal_apply_normalize_merge__(node, current, length, parent, index)
      if @start_container.equal?(current)
        @start_container = node
        @start_offset += length
      elsif parent && @start_container.equal?(parent) && @start_offset == index
        @start_container = node
        @start_offset = length
      end
      if @end_container.equal?(current)
        @end_container = node
        @end_offset += length
      elsif parent && @end_container.equal?(parent) && @end_offset == index
        @end_container = node
        @end_offset = length
      end
      nil
    end

    # "Remove" steps, run while the node is still attached.
    def __internal_apply_remove__(node, parent, index)
      if inclusive_ancestor?(node, @start_container)
        @start_container = parent
        @start_offset = index
      end
      if inclusive_ancestor?(node, @end_container)
        @end_container = parent
        @end_offset = index
      end
      @start_offset -= 1 if @start_container.equal?(parent) && @start_offset > index
      @end_offset -= 1 if @end_container.equal?(parent) && @end_offset > index
      nil
    end

    # "Insert" step: a node inserted at `index` pushes later boundary points in
    # the same parent along by one.
    def __internal_apply_insert__(parent, index)
      @start_offset += 1 if @start_container.equal?(parent) && @start_offset > index
      @end_offset += 1 if @end_container.equal?(parent) && @end_offset > index
      nil
    end

    # Cheap pre-checks the document uses to decide whether a mutation is worth
    # resolving a child index for. Computing an index means walking the parent's
    # child list, which would turn a bulk append into quadratic work if it ran
    # for every insertion regardless of where the live ranges actually sit.

    def __internal_anchored_at__(parent)
      @start_container.equal?(parent) || @end_container.equal?(parent)
    end

    def __internal_affected_by_removal__(node, parent)
      __internal_anchored_at__(parent) ||
        inclusive_ancestor?(node, @start_container) ||
        inclusive_ancestor?(node, @end_container)
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
      offset = validate_boundary!(node, offset)
      # A boundary in a different tree carries the whole range with it; otherwise
      # a start past the end collapses the range onto the new start.
      different_root = !same_root?(node)
      @start_container = node
      @start_offset = offset
      if different_root || compare_points(@start_container, @start_offset, @end_container, @end_offset) > 0
        collapse_to_start
      end
      nil
    end

    def set_end(node, offset)
      offset = validate_boundary!(node, offset)
      different_root = !same_root?(node)
      @end_container = node
      @end_offset = offset
      if different_root || compare_points(@start_container, @start_offset, @end_container, @end_offset) > 0
        collapse_to_end
      end
      nil
    end

    # WHATWG "set the start/end of a range" steps 1-2: a DocumentType can never
    # hold a boundary, and the offset is an unsigned long bounded by the node's
    # length (so a negative JS offset wraps to a huge value and is rejected).
    def validate_boundary!(node, offset)
      raise DOMException::InvalidNodeTypeError, "a DocumentType cannot be a boundary point" if doctype?(node)

      value = unsigned_long(offset)
      raise DOMException::IndexSizeError, "offset #{value} is past the node's length" if value > length_of(node)

      value
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

    # `createContextualFragment(html)` — parse an HTML string into a
    # DocumentFragment using the range's start node as the parsing context
    # (DOM Parsing & Serialization). Frameworks use it to turn an HTML string
    # into nodes (Nuxt's DOM hydration / `<slot>` helpers call it via a Range).
    def create_contextual_fragment(html)
      context = @document.create_element(contextual_local_name)
      # WebIDL DOMString coercion: JS null stringifies to "null" (no
      # [LegacyNullToEmptyString] here), the UNDEFINED sentinel to "undefined".
      context.inner_html = html.nil? ? "null" : html.to_s # fragment-parses in the context element
      fragment = @document.create_document_fragment
      context.child_nodes.to_a.each { |child| fragment.append_child(child) }
      fragment
    end

    # --- Content extraction ----------------------------------------

    def to_s
      Internal::RangeTextSerializer.new(self).serialize
    end

    # cloneContents — a DocumentFragment holding a copy of the range contents.
    # The tree is left unchanged. Partially-contained nodes are copied only as
    # far as the range reaches into them (WHATWG "clone the contents of a
    # range"), so a range ending mid-text yields the leading substring, not the
    # whole node.
    def clone_contents
      copy_or_move(@start_container, @start_offset, @end_container, @end_offset, extract: false)
    end

    # extractContents — like cloneContents, but the contents are *moved* into
    # the fragment (fully-contained nodes keep their identity) and the range
    # collapses to the point the removal leaves behind.
    def extract_contents
      return @document.create_document_fragment if collapsed?

      sc = @start_container
      so = @start_offset
      ec = @end_container
      eo = @end_offset
      # The collapse point has to be computed against the *pre-mutation* tree.
      new_node, new_offset = deletion_collapse_point(sc, so, ec, eo)
      fragment = copy_or_move(sc, so, ec, eo, extract: true)
      @start_container = @end_container = new_node
      @start_offset = @end_offset = new_offset
      fragment
    end

    # WHATWG "clone/extract the contents of a range" — one recursive walk, since
    # the two algorithms differ only in whether the source is mutated and whether
    # fully-contained nodes are moved or deep-copied.
    def copy_or_move(sc, so, ec, eo, extract:)
      fragment = @document.create_document_fragment
      return fragment if sc.equal?(ec) && so == eo

      # Both boundaries inside one CharacterData node: a single substring.
      if sc.equal?(ec) && character_data?(sc)
        clone = shallow_clone(sc)
        clone.data = Internal::Utf16.slice(sc.data.to_s, so, eo - so)
        fragment.append_child(clone)
        sc.replace_data(so, eo - so, "") if extract
        return fragment
      end

      common = common_ancestor_of(sc, ec)
      children = common.respond_to?(:child_nodes) ? common.child_nodes.to_a : []
      first_partial = inclusive_ancestor?(sc, ec) ? nil : children.find { |c| partially_contained?(c, sc, ec) }
      last_partial = inclusive_ancestor?(ec, sc) ? nil : children.reverse.find { |c| partially_contained?(c, sc, ec) }
      contained = children.select { |c| contained_between?(c, sc, so, ec, eo) }

      if contained.any? { |node| doctype?(node) }
        raise DOMException::HierarchyRequestError, "cannot extract a doctype from a range"
      end

      append_start_boundary(fragment, sc, so, first_partial, extract: extract)
      contained.each { |child| fragment.append_child(extract ? child : clone_wrapped(child)) }
      append_end_boundary(fragment, ec, eo, last_partial, extract: extract)

      fragment
    end

    # Step 10: the start boundary's contribution — the tail of a boundary text
    # node, or a shallow copy of the partially-contained child holding whatever
    # the range reaches inside it.
    def append_start_boundary(fragment, sc, so, first_partial, extract:)
      return if first_partial.nil?

      if character_data?(first_partial)
        clone = shallow_clone(sc)
        clone.data = Internal::Utf16.suffix(sc.data.to_s, so)
        fragment.append_child(clone)
        sc.replace_data(so, length_of(sc) - so, "") if extract
      else
        clone = shallow_clone(first_partial)
        fragment.append_child(clone)
        clone.append_child(copy_or_move(sc, so, first_partial, length_of(first_partial), extract: extract))
      end
    end

    # Step 12: the mirror of `append_start_boundary` for the end boundary.
    def append_end_boundary(fragment, ec, eo, last_partial, extract:)
      return if last_partial.nil?

      if character_data?(last_partial)
        clone = shallow_clone(ec)
        clone.data = Internal::Utf16.slice(ec.data.to_s, 0, eo)
        fragment.append_child(clone)
        ec.replace_data(0, eo, "") if extract
      else
        clone = shallow_clone(last_partial)
        fragment.append_child(clone)
        clone.append_child(copy_or_move(last_partial, 0, ec, eo, extract: extract))
      end
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

      # Both boundaries in the same CharacterData node: just delete the run.
      # "Replace data" (not a whole-node `data=`) is what the spec calls for, and
      # it is also what leaves the collapsed boundary at `so` rather than
      # clamping it to 0 — plus its offsets are UTF-16 code units.
      if sc.equal?(ec) && character_data?(sc)
        sc.replace_data(so, eo - so, "")
        return nil
      end

      to_remove = nodes_to_remove
      new_node, new_offset = deletion_collapse_point(sc, so, ec, eo)

      # Trim the start boundary text node's tail, remove the contained nodes,
      # then trim the end boundary text node's head (order matters for records).
      sc.replace_data(so, length_of(sc) - so, "") if character_data?(sc)
      to_remove.each do |node|
        if node.respond_to?(:__dommy_backend_node__)
          @document.remove_node_with_notify(node.__dommy_backend_node__)
        elsif node.respond_to?(:remove)
          node.remove
        end
      end
      ec.replace_data(0, eo, "") if character_data?(ec)

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
      contained_between?(node, @start_container, @start_offset, @end_container, @end_offset)
    end

    # `node_fully_contained?` against explicit boundaries, for the recursive
    # clone/extract walk (which works on sub-ranges, not on `self`).
    def contained_between?(node, sc, so, ec, eo)
      parent = parent_of(node)
      return false unless parent

      idx = child_index_of(parent, node)
      compare_points(parent, idx, sc, so) >= 0 && compare_points(parent, idx + 1, ec, eo) <= 0
    end

    # WHATWG "partially contained": an inclusive ancestor of exactly one of the
    # range's two boundary nodes — i.e. the range reaches into it but does not
    # cover it.
    def partially_contained?(node, sc, ec)
      inclusive_ancestor?(node, sc) != inclusive_ancestor?(node, ec)
    end

    # The "common ancestor" the clone/extract algorithms use: the start node's
    # lowest inclusive ancestor that is also an inclusive ancestor of the end
    # node.
    def common_ancestor_of(sc, ec)
      node = sc
      node = parent_of(node) while node && !inclusive_ancestor?(node, ec)
      node || @document
    end

    # Text / CDATASection / ProcessingInstruction / Comment — the node types
    # whose "length" is a character count, so a range boundary can sit inside one.
    def character_data?(node)
      [3, 4, 7, 8].include?(node_type_of(node))
    end

    def shallow_clone(node)
      node.__js_call__("cloneNode", [false])
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

    # surroundContents(newParent) — wraps the range contents in newParent.
    def surround_contents(new_parent)
      # A non-Text node the range only reaches *into* cannot be surrounded: the
      # result would not be a well-formed tree.
      partial = ancestor_chain(@start_container) + ancestor_chain(@end_container)
      if partial.any? { |n| !text_node?(n) && partially_contained?(n, @start_container, @end_container) }
        raise DOMException::InvalidStateError, "a non-Text node is partially contained in the range"
      end

      if [9, 10, 11].include?(node_type_of(new_parent)) # Document / DocumentType / DocumentFragment
        raise DOMException::InvalidNodeTypeError, "newParent cannot be a Document, DocumentType or DocumentFragment"
      end

      fragment = extract_contents
      # "Replace all" with null: newParent is emptied before it takes the
      # contents. Insert it first, then fill it — inserting a populated wrapper
      # would place its children relative to the wrong boundary.
      new_parent.child_nodes.to_a.each { |child| child.remove }
      insert_node(new_parent)
      new_parent.append_child(fragment)
      select_node(new_parent)
      nil
    end

    def insert_node(node)
      # Insert at the range start. For a text container, split it at the offset
      # (when interior) and insert before the split-off tail — matching the spec,
      # which produces a childList record for the split plus one for the insert.
      sc = @start_container
      if text_node?(sc)
        parent = parent_of(sc)
        idx = child_index_of(parent, sc)
        if @start_offset.zero?
          insert_into_parent_at(parent, idx, node)
        elsif @start_offset >= length_of(sc)
          insert_into_parent_at(parent, idx + 1, node)
        else
          tail = sc.split_text(@start_offset)
          parent.insert_before(node, tail)
        end
      else
        insert_into_parent_at(sc, @start_offset, node)
      end

      nil
    end

    # --- Ordering / containment ------------------------------------

    def compare_boundary_points(how, other)
      # `how` is a WebIDL `unsigned short`: coerce first (NaN/±0/±Infinity → 0,
      # otherwise truncate toward zero and take modulo 2^16), then require one of
      # the four named constants, else NotSupportedError.
      how = to_unsigned_short(how)
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
      # WHATWG Range.intersectsNode: a node in a different tree never intersects;
      # a node with no parent (a tree root, e.g. the document) always does.
      return false unless same_root?(node)
      return true if parent_of(node).nil?

      # Otherwise range and node intersect iff node's position relative to the
      # range is not entirely before or entirely after it.
      return false if before?(node)
      return false if after?(node)

      true
    end

    # WHATWG Range.comparePoint(node, offset): -1 if (node, offset) is before the
    # range, 0 if inside, 1 if after. offset is a WebIDL unsigned long (so -1
    # wraps to a huge value > length → IndexSizeError).
    def compare_point(node, offset)
      raise Bridge::TypeError, "argument is not a Node" unless node.is_a?(Dommy::Node)

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
      when "START_TO_START"
        START_TO_START
      when "START_TO_END"
        START_TO_END
      when "END_TO_END"
        END_TO_END
      when "END_TO_START"
        END_TO_START
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[
      setStart setEnd setStartBefore setStartAfter setEndBefore setEndAfter collapse selectNode
      selectNodeContents toString cloneContents extractContents deleteContents surroundContents
      insertNode compareBoundaryPoints intersectsNode containsNode cloneRange detach
      comparePoint isPointInRange getBoundingClientRect getClientRects createContextualFragment
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
      when "createContextualFragment"
        # WebIDL required argument: a bare call (0 args) throws TypeError.
        raise Bridge::TypeError, "createContextualFragment requires 1 argument, but only 0 present" if args.empty?

        create_contextual_fragment(args[0])
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

    # The local name of the element to fragment-parse in: the start node if it
    # is an element, else its nearest element ancestor; falling back to "body"
    # (the HTML fragment-parsing context) for a document/fragment/`<html>` start.
    def contextual_local_name
      node = @start_container
      el = node.respond_to?(:node_type) && node.node_type == 1 ? node : (node.respond_to?(:parent_element) ? node.parent_element : nil)
      name = el&.local_name
      name.nil? || name.casecmp?("html") ? "body" : name
    end

    def collapse_to_start
      @end_container = @start_container
      @end_offset = @start_offset
    end

    def collapse_to_end
      @start_container = @end_container
      @start_offset = @end_offset
    end

    def text_node?(node)
      node_type_of(node) == 3
    end

    # WHATWG "length of a node": a DocumentType is 0; a CharacterData node
    # (Text / CDATASection / ProcessingInstruction / Comment) is its data
    # length; any other node is its number of children.
    def length_of(node)
      case node.respond_to?(:node_type) ? node.node_type : nil
      when 10 # DocumentType
        0
      when 3, 4, 7, 8 # Text, CDATASection, ProcessingInstruction, Comment
        # A CharacterData node's length is its data length in UTF-16 code units
        # (an astral character counts 2), NOT Ruby code points.
        node.respond_to?(:data) ? Internal::Utf16.length(node.data.to_s) : 0
      else
        node.respond_to?(:child_nodes) ? node.child_nodes.length : 0
      end
    end

    # WebIDL unsigned long: wrap modulo 2^32 (so -1 → 4294967295).
    def unsigned_long(value)
      value.to_i % (2**32)
    end

    # WebIDL `unsigned short` conversion: ToNumber, then NaN/±0/±Infinity → 0,
    # otherwise truncate toward zero and take modulo 2^16.
    def to_unsigned_short(value)
      num = web_to_number(value)
      return 0 if num.nan? || num.zero? || num.infinite?

      ((num.negative? ? -1 : 1) * num.abs.floor) % 65536
    end

    # WebIDL ToNumber for the values that reach a bridged argument.
    def web_to_number(value)
      case value
      when Numeric then value.to_f
      when nil, false then 0.0
      when true then 1.0
      when String
        stripped = value.strip
        return 0.0 if stripped.empty?

        begin
          Float(stripped)
        rescue ArgumentError
          Float::NAN
        end
      else
        Float::NAN
      end
    end

    # Two nodes share a root iff their topmost ancestors are the same node.
    def same_root?(node)
      ancestor_chain(node).last.equal?(ancestor_chain(@start_container).last)
    end

    def doctype?(node)
      node_type_of(node) == 10
    end

    # Document / Fragment / DocumentType expose nodeType only over the bridge,
    # while Element and CharacterData also have a Ruby reader — ask both.
    def node_type_of(node)
      if node.respond_to?(:node_type)
        node.node_type
      elsif node.respond_to?(:__js_get__)
        nt = node.__js_get__("nodeType")
        nt.is_a?(Integer) ? nt : nil
      end
    end

    def insert_into_parent_at(parent, idx, node)
      children = parent.respond_to?(:child_nodes) ? parent.child_nodes.to_a : []
      if idx >= children.length
        parent.append_child(node) if parent.respond_to?(:append_child)
      elsif parent.respond_to?(:insert_before)
        # insert_before extracts a DocumentFragment's children in order and fires
        # the fragment-removal + target-addition records; `anchor.before` coerces
        # the fragment to a single node and reverses multi-node order.
        parent.insert_before(node, children[idx])
      elsif children[idx].respond_to?(:before)
        children[idx].before(node)
      else
        parent.append_child(node) if parent.respond_to?(:append_child)
      end
    end

    def clone_wrapped(node)
      return nil unless node.respond_to?(:__js_call__)

      node.__js_call__("cloneNode", [true])
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
      else
        Bridge::ABSENT
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
