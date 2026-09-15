# frozen_string_literal: true

module Dommy
  # `Selection` — a document's selection: at most one range, and a direction
  # that decides which end of it is the anchor and which the focus.
  #
  # Every method that selects something new builds a new Range instead of
  # changing the current one; addRange keeps the caller's Range by reference,
  # and deleteFromDocument is the one method that works on the range itself.
  # The members that need rendering (modify, the selectionchange event) and
  # getComposedRanges (which returns StaticRanges) are not modelled.
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
    VALUE_RETURNING = %w[getRangeAt containsNode toString].freeze

    def initialize(document)
      @document = document
      @range = nil
      @direction = :none
    end

    # --- anchor, focus, and what is read off them ---------------------------

    # The anchor and focus as the attributes report them: null (offset 0) once
    # the point has left the document tree.
    def anchor_node
      visible(anchor)&.first
    end

    def anchor_offset
      visible(anchor)&.last || 0
    end

    def focus_node
      visible(focus)&.first
    end

    def focus_offset
      visible(focus)&.last || 0
    end

    # Compares the anchor and focus themselves, wherever they are.
    def is_collapsed
      @range.nil? || @range.collapsed?
    end

    alias isCollapsed is_collapsed

    def range_count
      in_document_tree? ? 1 : 0
    end

    def type
      return "None" unless in_document_tree?

      @range.collapsed? ? "Caret" : "Range"
    end

    def direction
      @range ? DIRECTION_NAMES.fetch(@direction) : "none"
    end

    def get_range_at(index)
      unless Internal::WebIDL.unsigned_long(index).zero? && in_document_tree?
        raise DOMException::IndexSizeError, "the selection has no range at index #{index}"
      end

      @range
    end

    def to_s
      @range ? @range.to_s : ""
    end

    # --- setting the range ----------------------------------------------------

    # addRange sets no direction of its own. A forwards one keeps the anchor at
    # the range's start, which is what engines report and WPT
    # (selection/addRange.htm) checks.
    def add_range(range)
      Internal::WebIDL.interface!(range, Range)
      return nil unless root_of(range.start_container).equal?(@document)
      return nil unless range_count.zero?

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
      # they take the "otherwise" branches: focus first, and forwards.
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
      @range.delete_contents if in_document_tree?
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
      extend setBaseAndExtent selectAllChildren deleteFromDocument containsNode toString
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
        when "toString"
          to_s
        end
      VALUE_RETURNING.include?(method) ? result : Bridge::UNDEFINED
    end

    private

    def replace_range(range, direction)
      @range = range
      @direction = direction
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

    def visible(point)
      point if point && root_of(point.first).equal?(@document)
    end

    # Both ends of the range are in the document tree — not in a shadow tree
    # or a detached subtree. rangeCount, type and getRangeAt all ask this.
    def in_document_tree?
      !@range.nil? && root_of(@range.start_container).equal?(@document) &&
        root_of(@range.end_container).equal?(@document)
    end

    # The document is a shadow-including inclusive ancestor of `node`.
    def in_this_document?(node)
      node.get_root_node({ "composed" => true }).equal?(@document)
    end

    def root_of(node)
      node.get_root_node
    end
  end
end
