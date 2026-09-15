# frozen_string_literal: true

module Dommy
  # `Selection` — a document's selection: at most one range, and a direction
  # that decides which end of it is the anchor and which the focus.
  #
  # Every method that selects something new builds a new Range instead of
  # changing the current one; addRange keeps the caller's Range by reference,
  # and deleteFromDocument is the one method that works on the range itself.
  # The members that need rendering (modify, the selectionchange event) are not
  # modelled.
  #
  # The selection has one state: it has a range, or it is empty. A range that
  # leaves the document — moved by script into a fragment or another document,
  # or stranded in a shadow tree whose host was removed — is dropped on the
  # spot and does not come back if it is moved back in. That is what Blink and
  # Gecko do (and WPT's selection/*different-root*.tentative.html expects), and
  # it keeps rangeCount, type, isCollapsed, toString and collapseToStart/End
  # telling the same story. The spec text instead keeps such a range associated
  # and hides it member by member. A range in a shadow tree of this document
  # stays: the spec notes anchor and focus may be there, and the engines report
  # them.
  #
  # Spec: https://w3c.github.io/selection-api/
  class Selection
    DIRECTION_NAMES = { forwards: "forward", backwards: "backward", none: "none" }.freeze

    # WebIDL required-argument counts of the bridged operations.
    REQUIRED_ARGUMENTS = {
      "getRangeAt" => 1, "addRange" => 1, "removeRange" => 1, "collapse" => 1, "setPosition" => 1,
      "extend" => 1, "setBaseAndExtent" => 4, "selectAllChildren" => 1, "containsNode" => 1
    }.freeze

    # The bridged operations that return a value; the rest are `undefined`.
    VALUE_RETURNING = %w[getRangeAt getComposedRanges containsNode toString].freeze

    def initialize(document)
      @document = document
      @range = nil
      @direction = :none
    end

    # --- anchor, focus, and what is read off them ---------------------------

    def anchor_node
      anchor&.first
    end

    def anchor_offset
      anchor&.last || 0
    end

    def focus_node
      focus&.first
    end

    def focus_offset
      focus&.last || 0
    end

    def is_collapsed
      @range.nil? || @range.collapsed?
    end

    alias isCollapsed is_collapsed

    def range_count
      @range ? 1 : 0
    end

    def type
      return "None" if @range.nil?

      @range.collapsed? ? "Caret" : "Range"
    end

    def direction
      @range ? DIRECTION_NAMES.fetch(@direction) : "none"
    end

    def get_range_at(index)
      unless Internal::WebIDL.unsigned_long(index).zero? && @range
        raise DOMException::IndexSizeError, "the selection has no range at index #{index}"
      end

      @range
    end

    def to_s
      @range ? @range.to_s : ""
    end

    # `getComposedRanges({shadowRoots})`: the range as a new StaticRange, each
    # end lifted out of any shadow tree the caller did not list to its host's
    # place in the parent. A ShadowRoot passed on its own (an older form of the
    # call) is an object without the member, so it lists nothing — which is how
    # Blink reads it; Gecko still honours that form.
    def get_composed_ranges(options = nil)
      shadow_roots = listed_shadow_roots(options)
      return [] if @range.nil?

      start_node, start_offset = lift_out_of_unlisted_shadow_trees(*start_point, shadow_roots, 0)
      end_node, end_offset = lift_out_of_unlisted_shadow_trees(*end_point, shadow_roots, 1)
      [StaticRange.new(start_node, start_offset, end_node, end_offset)]
    end

    # --- setting the range ----------------------------------------------------

    # addRange sets no direction of its own. A forwards one keeps the anchor at
    # the range's start, which is what engines report and WPT
    # (selection/addRange.htm) checks. The spec wants the range's root to be the
    # document itself; Blink and Gecko also take a range in one of its shadow
    # trees, and so does this, as the rest of the selection allows them.
    def add_range(range)
      Internal::WebIDL.interface!(range, Range)
      return nil unless connected?(range)
      return nil unless @range.nil?

      replace_range(range, :forwards)
    end

    def remove_range(range)
      Internal::WebIDL.interface!(range, Range)
      raise DOMException::NotFoundError, "the range is not this selection's range" unless range.equal?(@range)

      remove_all_ranges
    end

    def remove_all_ranges
      replace_range(nil, :none)
    end

    alias empty remove_all_ranges

    # `collapse(node, offset)`, also `setPosition`. A null node empties the
    # selection. The new range's own checks (a doctype, an offset past the
    # node's length) run before a node outside this document is quietly
    # ignored.
    def collapse(node, offset = 0)
      return remove_all_ranges if Internal::WebIDL.nullable_node!(node).nil?

      range = caret_range(node, offset)
      return nil unless in_this_document?(node)

      replace_range(range, :none)
    end

    alias set_position collapse

    def collapse_to_start
      raise DOMException::InvalidStateError, "the selection is empty" if @range.nil?

      replace_range(caret_range(*start_point), :none)
    end

    def collapse_to_end
      raise DOMException::InvalidStateError, "the selection is empty" if @range.nil?

      replace_range(caret_range(*end_point), :none)
    end

    # `extend(node, offset)`, named so as to leave Ruby's Object#extend alone.
    # The anchor stays and the focus moves to (node, offset); a node in another
    # tree than the range starts the selection over at that point.
    def extend_selection(node, offset = 0)
      Internal::WebIDL.node!(node)
      new_focus = [node, Internal::WebIDL.unsigned_long(offset)]
      return nil unless in_this_document?(node)
      raise DOMException::InvalidStateError, "the selection is empty" if @range.nil?

      old_anchor = anchor
      range = Range.new(@document)
      backwards = false
      if root_of(node).equal?(root_of(@range.start_container))
        backwards = range.__internal_compare_points__(*new_focus, *old_anchor).negative?
        start, finish = backwards ? [new_focus, old_anchor] : [old_anchor, new_focus]
      else
        start = finish = new_focus
      end
      range.set_start(*start)
      range.set_end(*finish)
      replace_range(range, backwards ? :backwards : :forwards)
    end

    def set_base_and_extent(anchor_node, anchor_offset, focus_node, focus_offset)
      Internal::WebIDL.node!(anchor_node)
      anchor_point = [anchor_node, Internal::WebIDL.unsigned_long(anchor_offset)]
      Internal::WebIDL.node!(focus_node)
      focus_point = [focus_node, Internal::WebIDL.unsigned_long(focus_offset)]
      range = Range.new(@document)
      if [anchor_point, focus_point].any? { |node, offset| offset > range.__internal_length_of__(node) }
        raise DOMException::IndexSizeError, "an offset is past its node's length"
      end
      return nil unless in_this_document?(anchor_node) && in_this_document?(focus_node)

      # Points in different trees are neither before nor after one another, so
      # they take the "otherwise" branches: the start is set to the focus, then
      # the end to the anchor, which carries the range over to the anchor.
      # Blink and Gecko land there too.
      same_tree = root_of(anchor_node).equal?(root_of(focus_node))
      anchor_first = same_tree && range.__internal_compare_points__(*anchor_point, *focus_point).negative?
      backwards = same_tree && range.__internal_compare_points__(*focus_point, *anchor_point).negative?
      start, finish = anchor_first ? [anchor_point, focus_point] : [focus_point, anchor_point]
      range.set_start(*start)
      range.set_end(*finish)
      replace_range(range, backwards ? :backwards : :forwards)
    end

    # The range runs over the node's children, not its length: a Text node's
    # children end at offset 0.
    def select_all_children(node)
      Internal::WebIDL.node!(node)
      raise DOMException::InvalidNodeTypeError, "a DocumentType has no children to select" if node.is_a?(DocumentType)
      return nil unless root_of(node).equal?(@document)

      range = Range.new(@document)
      range.set_start(node, 0)
      range.set_end(node, node.respond_to?(:child_nodes) ? node.child_nodes.length : 0)
      replace_range(range, :forwards)
    end

    def delete_from_document
      @range&.delete_contents
      nil
    end

    # Wholly contained: the range starts at or before the node's first boundary
    # point and ends at or after its last. Partially: it starts at or before the
    # node's last point and ends at or after its first.
    def contains_node(node, allow_partial_containment = false)
      Internal::WebIDL.node!(node)
      return false if @range.nil? || !root_of(node).equal?(@document)

      first = [node, 0]
      last = [node, @range.__internal_length_of__(node)]
      inner_start, inner_end = EventTarget.js_truthy?(allow_partial_containment) ? [last, first] : [first, last]
      @range.__internal_compare_points__(*start_point, *inner_start) <= 0 &&
        @range.__internal_compare_points__(*end_point, *inner_end) >= 0
    end

    # --- keeping the range in the document ---------------------------------------

    # The range told us its boundaries moved.
    def __internal_range_moved__(range)
      remove_all_ranges if range.equal?(@range) && !connected?(range)
      nil
    end

    # The document removed a node; a shadow host going takes its shadow tree,
    # and a range in it, out of the document without moving the range.
    def __internal_node_removed__
      remove_all_ranges if @range && !connected?(@range)
      nil
    end

    # --- JS bridge ------------------------------------------------------------

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
        type
      when "direction"
        direction
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[
      getRangeAt addRange removeRange removeAllRanges empty collapse setPosition collapseToStart collapseToEnd
      extend setBaseAndExtent selectAllChildren deleteFromDocument containsNode getComposedRanges toString
    ]
    def __js_call__(method, args)
      required = REQUIRED_ARGUMENTS.fetch(method, 0)
      if args.length < required
        raise Bridge::TypeError, "#{method} requires #{required} argument(s), but only #{args.length} present"
      end

      result =
        case method
        when "getRangeAt"
          get_range_at(args[0])
        when "addRange"
          add_range(args[0])
        when "removeRange"
          remove_range(args[0])
        when "removeAllRanges", "empty"
          remove_all_ranges
        when "collapse", "setPosition"
          collapse(args[0], args.fetch(1, 0))
        when "collapseToStart"
          collapse_to_start
        when "collapseToEnd"
          collapse_to_end
        when "extend"
          extend_selection(args[0], args.fetch(1, 0))
        when "setBaseAndExtent"
          set_base_and_extent(*args.first(4))
        when "selectAllChildren"
          select_all_children(args[0])
        when "deleteFromDocument"
          delete_from_document
        when "containsNode"
          contains_node(args[0], args.fetch(1, false))
        when "getComposedRanges"
          get_composed_ranges(args[0])
        when "toString"
          to_s
        end
      VALUE_RETURNING.include?(method) ? result : Bridge::UNDEFINED
    end

    private

    # Associates `range` (or nothing) with the selection. The range reports its
    # boundary moves to whichever selection holds it.
    def replace_range(range, direction)
      @range&.__internal_associate__(nil) unless @range.equal?(range)
      @range = range
      @direction = direction
      range&.__internal_associate__(self)
      nil
    end

    # A new collapsed range at (node, offset), through the Range's own checks.
    def caret_range(node, offset)
      range = Range.new(@document)
      range.set_start(node, offset)
      range.set_end(node, offset)
      range
    end

    def start_point
      [@range.start_container, @range.start_offset]
    end

    def end_point
      [@range.end_container, @range.end_offset]
    end

    # The anchor is the range's start only when the selection runs forwards;
    # a backwards or directionless selection is anchored at the end.
    def anchor
      @range && (@direction == :forwards ? start_point : end_point)
    end

    def focus
      @range && (@direction == :forwards ? end_point : start_point)
    end

    # A range's two boundaries always share a root, so its start answers for both.
    def connected?(range)
      in_this_document?(range.start_container)
    end

    # The document is a shadow-including inclusive ancestor of `node`.
    def in_this_document?(node)
      node.get_root_node({ "composed" => true }).equal?(@document)
    end

    def root_of(node)
      node.get_root_node
    end

    # GetComposedRangesOptions, converted: nothing, undefined, or an object
    # without the member lists no shadow roots; `shadowRoots` has to be a
    # sequence of ShadowRoots; anything that is not an object is a TypeError.
    def listed_shadow_roots(options)
      return [] if options.nil? || options.equal?(Bridge::UNDEFINED)
      unless options.is_a?(Hash)
        raise Bridge::TypeError, "GetComposedRangesOptions must be an object" unless options.respond_to?(:__js_get__)

        return []
      end

      roots = options.fetch("shadowRoots", Bridge::UNDEFINED)
      return [] if roots.equal?(Bridge::UNDEFINED)
      raise Bridge::TypeError, "shadowRoots must be a sequence" unless roots.is_a?(Array)

      roots.map { |root| Internal::WebIDL.interface!(root, ShadowRoot) }
    end

    # getComposedRanges steps 2-3: while the point sits in a shadow tree that
    # holds none of the listed roots, move it to its host's place in the parent
    # — before the host for the start (`past` 0), after it for the end (1).
    def lift_out_of_unlisted_shadow_trees(node, offset, shadow_roots, past)
      root = root_of(node)
      while root.is_a?(ShadowRoot) && shadow_roots.none? { |listed| holds_shadow_root?(root, listed) }
        host = root.host
        node = host.parent_node
        offset = node.child_nodes.to_a.index { |child| child.equal?(host) } + past
        root = root_of(node)
      end
      [node, offset]
    end

    # Whether shadow root `root` is `listed` or a shadow-including ancestor of
    # it: climbing out of `listed` host by host reaches `root`.
    def holds_shadow_root?(root, listed)
      current = listed
      while current.is_a?(ShadowRoot)
        return true if current.equal?(root)

        current = root_of(current.host)
      end
      false
    end
  end
end
