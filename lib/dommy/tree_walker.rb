# frozen_string_literal: true

module Dommy
  # NodeFilter constants — bitmasks for `whatToShow` and return values
  # for the optional filter callable. Standard DOM Level 2 Traversal.
  module NodeFilter
    SHOW_ALL = 0xFFFFFFFF
    SHOW_ELEMENT = 0x1
    SHOW_ATTRIBUTE = 0x2
    SHOW_TEXT = 0x4
    SHOW_CDATA_SECTION = 0x8
    SHOW_PROCESSING_INSTRUCTION = 0x40
    SHOW_COMMENT = 0x80
    SHOW_DOCUMENT = 0x100
    SHOW_DOCUMENT_TYPE = 0x200
    SHOW_DOCUMENT_FRAGMENT = 0x400

    FILTER_ACCEPT = 1
    FILTER_REJECT = 2
    FILTER_SKIP = 3

    # Map a wrapped Dommy node to its NodeFilter bitmask. Returns 0
    # for unknown node types (effectively "doesn't pass any filter").
    def self.bitmask_for(node)
      case node
      when Element
        SHOW_ELEMENT
      when TextNode
        SHOW_TEXT
      when CommentNode
        SHOW_COMMENT
      when Fragment
        SHOW_DOCUMENT_FRAGMENT
      when Document
        SHOW_DOCUMENT
      when DocumentType
        SHOW_DOCUMENT_TYPE
      else
        0
      end
    end
  end

  # Shared helpers between TreeWalker and NodeIterator. Both walk the
  # tree rooted at `root` and filter by `whatToShow` + an optional
  # filter callable (or object with `acceptNode`).
  module TreeTraversalCore
    private

    # Returns FILTER_ACCEPT / FILTER_REJECT / FILTER_SKIP for the
    # given wrapped node.
    def accept(node)
      return NodeFilter::FILTER_REJECT unless node
      return NodeFilter::FILTER_SKIP if (NodeFilter.bitmask_for(node) & @what_to_show) == 0

      result = invoke_filter(node)
      result || NodeFilter::FILTER_ACCEPT
    end

    def invoke_filter(node)
      return NodeFilter::FILTER_ACCEPT if @filter.nil?

      if @filter.respond_to?(:accept_node)
        @filter.accept_node(node)
      elsif @filter.respond_to?(:call)
        @filter.call(node)
      else
        NodeFilter::FILTER_ACCEPT
      end
    end
  end

  # TreeWalker — stateful traversal with `next_node` / `previous_node`
  # / `parent_node` / `first_child` / `last_child` / `next_sibling` /
  # `previous_sibling` and a mutable `current_node` cursor.
  #
  # Wraps Nokogiri descent; doesn't snapshot the tree, so mutations
  # during traversal are visible (matches DOM spec).
  class TreeWalker
    include TreeTraversalCore

    attr_reader :root, :what_to_show, :filter
    attr_accessor :current_node

    def initialize(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      @root = root
      @what_to_show = what_to_show.to_i
      @filter = filter
      @current_node = root
    end

    def next_node
      node = first_descendant_or_following(@current_node)
      while node
        verdict = accept(node)
        if verdict == NodeFilter::FILTER_ACCEPT
          @current_node = node
          return node
        end

        node = (verdict == NodeFilter::FILTER_REJECT) ? following_skip_subtree(node) : first_descendant_or_following(
          node
        )
      end

      nil
    end

    def previous_node
      node = preceding(@current_node)
      while node && node != @root
        verdict = accept(node)
        if verdict == NodeFilter::FILTER_ACCEPT
          @current_node = node
          return node
        end

        node = preceding(node)
      end

      nil
    end

    def parent_node
      node = wrapped_parent(@current_node)
      while node && reachable_from_root?(node)
        return @current_node = node if accept(node) == NodeFilter::FILTER_ACCEPT

        node = wrapped_parent(node)
      end

      nil
    end

    def first_child
      first = first_wrapped_child(@current_node)
      walk_siblings(first, :next_sibling_wrapped)
    end

    def last_child
      last = last_wrapped_child(@current_node)
      walk_siblings(last, :previous_sibling_wrapped)
    end

    def next_sibling
      walk_siblings(next_sibling_wrapped(@current_node), :next_sibling_wrapped)
    end

    def previous_sibling
      walk_siblings(previous_sibling_wrapped(@current_node), :previous_sibling_wrapped)
    end

    def __js_get__(key)
      case key
      when "root"
        @root
      when "whatToShow"
        @what_to_show
      when "filter"
        @filter
      when "currentNode"
        @current_node
      end
    end

    def __js_set__(key, value)
      @current_node = value if key == "currentNode"
      nil
    end

    def __js_call__(method, _args)
      case method
      when "nextNode"
        next_node
      when "previousNode"
        previous_node
      when "parentNode"
        parent_node
      when "firstChild"
        first_child
      when "lastChild"
        last_child
      when "nextSibling"
        next_sibling
      when "previousSibling"
        previous_sibling
      end
    end

    private

    def walk_siblings(start, direction)
      node = start
      while node
        v = accept(node)
        return @current_node = node if v == NodeFilter::FILTER_ACCEPT

        node = (v == NodeFilter::FILTER_REJECT) ? nil : send(direction, node)
      end

      nil
    end

    def first_descendant_or_following(node)
      child = first_wrapped_child(node)
      return child if child

      following_skip_subtree(node)
    end

    def following_skip_subtree(node)
      current = node
      while current && current != @root
        sib = next_sibling_wrapped(current)
        return sib if sib

        current = wrapped_parent(current)
      end

      nil
    end

    def preceding(node)
      sib = previous_sibling_wrapped(node)
      if sib
        node = sib
        while (last = last_wrapped_child(node))
          node = last
        end

        return node
      end

      wrapped_parent(node)
    end

    def reachable_from_root?(node)
      current = node
      while current
        return true if current == @root

        current = wrapped_parent(current)
      end

      false
    end

    def wrapped_parent(node)
      parent_nk = node.respond_to?(:__node__) ? node.__node__.parent : nil
      return nil unless parent_nk && !parent_nk.is_a?(Backend.document_class)

      doc = node.instance_variable_get(:@document) || (@root.respond_to?(:document) ? @root.document : @root)
      doc.wrap_node(parent_nk)
    end

    def first_wrapped_child(node)
      child_nk = node.respond_to?(:__node__) ? node.__node__.children.first : nil
      child_nk && document_for(node).wrap_node(child_nk)
    end

    def last_wrapped_child(node)
      child_nk = node.respond_to?(:__node__) ? node.__node__.children.last : nil
      child_nk && document_for(node).wrap_node(child_nk)
    end

    def next_sibling_wrapped(node)
      n = node.respond_to?(:__node__) ? node.__node__.next : nil
      n && document_for(node).wrap_node(n)
    end

    def previous_sibling_wrapped(node)
      n = node.respond_to?(:__node__) ? node.__node__.previous : nil
      n && document_for(node).wrap_node(n)
    end

    def document_for(node)
      node.instance_variable_get(:@document) || @root.instance_variable_get(:@document) || @root
    end
  end

  # NodeIterator — flat-list traversal. Same filter semantics as
  # TreeWalker but no sibling/parent navigation, just `next_node` /
  # `previous_node` over a depth-first sequence anchored to `root`.
  class NodeIterator
    include TreeTraversalCore

    attr_reader :root, :what_to_show, :filter

    def initialize(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      @root = root
      @what_to_show = what_to_show.to_i
      @filter = filter
      @reference_node = root
      @pointer_before_reference = true
    end

    def next_node
      loop do
        node = if @pointer_before_reference
          @reference_node
        else
          next_in_document_order(@reference_node)
        end

        return nil unless node

        @reference_node = node
        @pointer_before_reference = false
        return node if accept(node) == NodeFilter::FILTER_ACCEPT
      end
    end

    def previous_node
      loop do
        node = if @pointer_before_reference
          previous_in_document_order(@reference_node)
        else
          @reference_node
        end

        return nil unless node

        @reference_node = node
        @pointer_before_reference = true
        return node if accept(node) == NodeFilter::FILTER_ACCEPT
      end
    end

    def detach
      nil
    end

    def __js_get__(key)
      case key
      when "root"
        @root
      when "whatToShow"
        @what_to_show
      when "filter"
        @filter
      when "referenceNode"
        @reference_node
      when "pointerBeforeReferenceNode"
        @pointer_before_reference
      end
    end

    def __js_call__(method, _args)
      case method
      when "nextNode"
        next_node
      when "previousNode"
        previous_node
      when "detach"
        detach
      end
    end

    private

    def next_in_document_order(node)
      return @root if node.nil?

      child = first_child_node(node)
      return child if child

      current = node
      while current && current != @root
        sib = next_sibling_node(current)
        return sib if sib

        current = parent_node_of(current)
      end

      nil
    end

    def previous_in_document_order(node)
      return nil if node.nil? || node == @root

      sib = previous_sibling_node(node)
      if sib
        node = sib
        while (last = last_child_node(node))
          node = last
        end

        return node
      end

      parent_node_of(node)
    end

    def first_child_node(node)
      n = node.respond_to?(:__node__) ? node.__node__.children.first : nil
      n && document_for(node).wrap_node(n)
    end

    def last_child_node(node)
      n = node.respond_to?(:__node__) ? node.__node__.children.last : nil
      n && document_for(node).wrap_node(n)
    end

    def next_sibling_node(node)
      n = node.respond_to?(:__node__) ? node.__node__.next : nil
      n && document_for(node).wrap_node(n)
    end

    def previous_sibling_node(node)
      n = node.respond_to?(:__node__) ? node.__node__.previous : nil
      n && document_for(node).wrap_node(n)
    end

    def parent_node_of(node)
      parent_nk = node.respond_to?(:__node__) ? node.__node__.parent : nil
      return nil unless parent_nk && !parent_nk.is_a?(Backend.document_class)

      document_for(node).wrap_node(parent_nk)
    end

    def document_for(node)
      node.instance_variable_get(:@document) || @root.instance_variable_get(:@document) || @root
    end
  end
end
