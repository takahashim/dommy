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
    # whatToShow bit for a node: WHATWG defines it as `1 << (nodeType - 1)`,
    # which covers every node type (Element, Text, CDATASection, PI, Comment,
    # Document, DocumentType, DocumentFragment, Attribute) uniformly.
    def self.bitmask_for(node)
      nt =
        if node.respond_to?(:node_type) then node.node_type
        elsif node.respond_to?(:__js_get__) then node.__js_get__("nodeType")
        end
      return 0 unless nt.is_a?(Integer) && nt >= 1

      1 << (nt - 1)
    end
  end

  # Shared helpers between TreeWalker and NodeIterator. Both walk the
  # tree rooted at `root` and filter by `whatToShow` + an optional
  # filter callable (or object with `acceptNode`).
  module TreeTraversalCore
    private

    # Returns FILTER_ACCEPT / FILTER_REJECT / FILTER_SKIP for the
    # given wrapped node. Per WHATWG "filter", the active-flag re-entrancy
    # check comes first: a NodeFilter that re-enters its own walker/iterator
    # (calls nextNode etc. while the filter is still running) is an
    # InvalidStateError.
    def accept(node)
      return NodeFilter::FILTER_REJECT unless node
      raise DOMException::InvalidStateError, "NodeFilter is already active" if @active
      return NodeFilter::FILTER_SKIP if (NodeFilter.bitmask_for(node) & @what_to_show) == 0

      result = invoke_filter(node)
      result || NodeFilter::FILTER_ACCEPT
    end

    def invoke_filter(node)
      return NodeFilter::FILTER_ACCEPT if @filter.nil? || (defined?(Bridge::UNDEFINED) && @filter.equal?(Bridge::UNDEFINED))

      cb = filter_callback
      # A non-null filter with no callable acceptNode is a TypeError when invoked.
      raise Bridge::TypeError, "NodeFilter is not callable" unless cb

      # The active flag is set around the user callback only; a re-entrant
      # traversal during this window trips the guard in `accept`. It must be
      # cleared even when the callback throws so the walker stays usable.
      @active = true
      result =
        begin
          # A NodeFilter's exception must propagate out of the traversal method,
          # so use the raising invocation when the callback supports it (a JS
          # function); a Ruby callable propagates naturally.
          if cb.respond_to?(:__js_call_with_raise__)
            cb.__js_call_with_raise__([node])
          elsif cb.respond_to?(:__js_call__)
            cb.__js_call__("call", [node])
          else
            cb.call(node)
          end
        ensure
          @active = false
        end
      # WebIDL coerces the filter return (an `unsigned short`): booleans and
      # null become 0/1, everything else ToInteger.
      return 1 if result == true
      return 0 if result == false || result.nil?

      result.to_i
    end

    # The actual filter callback: a function filter is called directly; an object
    # filter's `acceptNode` is used (WebIDL callback interface).
    def filter_callback
      return @filter if callable?(@filter)

      accept_node =
        if @filter.respond_to?(:accept_node) then @filter.method(:accept_node)
        elsif @filter.is_a?(Hash) then (@filter["acceptNode"] || @filter[:acceptNode])
        elsif @filter.respond_to?(:__js_get__) then @filter.__js_get__("acceptNode")
        end
      callable?(accept_node) ? accept_node : nil
    end

    def callable?(value)
      value && (value.respond_to?(:__js_call__) || value.respond_to?(:call))
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
      node = @current_node
      result = NodeFilter::FILTER_ACCEPT
      loop do
        while result != NodeFilter::FILTER_REJECT && (child = first_wrapped_child(node))
          node = child
          result = accept(node)
          return @current_node = node if result == NodeFilter::FILTER_ACCEPT
        end

        sibling = nil
        temp = node
        while temp
          return nil if temp == @root

          sibling = next_sibling_wrapped(temp)
          if sibling
            node = sibling
            break
          end
          temp = wrapped_parent(temp)
        end
        return nil unless sibling

        result = accept(node)
        return @current_node = node if result == NodeFilter::FILTER_ACCEPT
      end
    end

    def previous_node
      node = @current_node
      while node != @root
        sibling = previous_sibling_wrapped(node)
        while sibling
          node = sibling
          result = accept(node)
          while result != NodeFilter::FILTER_REJECT && (child = last_wrapped_child(node))
            node = child
            result = accept(node)
          end
          return @current_node = node if result == NodeFilter::FILTER_ACCEPT

          sibling = previous_sibling_wrapped(node)
        end

        parent = wrapped_parent(node)
        return nil if node == @root || parent.nil?

        node = parent
        return @current_node = node if accept(node) == NodeFilter::FILTER_ACCEPT
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
      traverse_children(:first_wrapped_child, :next_sibling_wrapped)
    end

    def last_child
      traverse_children(:last_wrapped_child, :previous_sibling_wrapped)
    end

    def next_sibling
      traverse_siblings(:next_sibling_wrapped, :first_wrapped_child)
    end

    def previous_sibling
      traverse_siblings(:previous_sibling_wrapped, :last_wrapped_child)
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
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      return Bridge::UNHANDLED unless key == "currentNode"

      # currentNode is a non-null `Node`; non-Node values are a TypeError.
      raise Bridge::TypeError, "currentNode must be a Node" unless value.is_a?(Dommy::Node)

      @current_node = value
      nil
    end

    include Bridge::Methods
    js_methods %w[nextNode previousNode parentNode firstChild lastChild nextSibling previousSibling]
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

    # WHATWG "traverse children": a SKIP node is transparent (descend into its
    # children); a REJECT node is opaque (skip it and its subtree, advance to the
    # next sibling, climbing toward currentNode as needed).
    def traverse_children(descend, sibling_dir)
      node = send(descend, @current_node)
      while node
        v = accept(node)
        return @current_node = node if v == NodeFilter::FILTER_ACCEPT

        if v == NodeFilter::FILTER_SKIP
          child = send(descend, node)
          if child
            node = child
            next
          end
        end

        loop do
          sib = send(sibling_dir, node)
          if sib
            node = sib
            break
          end
          parent = wrapped_parent(node)
          return nil if parent.nil? || parent == @root || parent == @current_node

          node = parent
        end
      end

      nil
    end

    # WHATWG "traverse siblings": walk siblings of currentNode; a SKIP sibling's
    # children are searched (descend), a REJECT sibling's subtree is skipped.
    def traverse_siblings(sibling_dir, child_dir)
      node = @current_node
      return nil if node == @root

      loop do
        sib = send(sibling_dir, node)
        while sib
          node = sib
          v = accept(node)
          return @current_node = node if v == NodeFilter::FILTER_ACCEPT

          sib = send(child_dir, node)
          sib = send(sibling_dir, node) if v == NodeFilter::FILTER_REJECT || sib.nil?
        end

        node = wrapped_parent(node)
        return nil if node.nil? || node == @root
        return nil if accept(node) == NodeFilter::FILTER_ACCEPT
      end
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
      parent_nk = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__.parent : nil
      return nil unless parent_nk && !parent_nk.is_a?(Backend.document_class)

      doc = node.instance_variable_get(:@document) || (@root.respond_to?(:document) ? @root.document : @root)
      doc.wrap_node(parent_nk)
    end

    # The Nokogiri node backing a wrapper — an element's `__dommy_backend_node__`
    # or, for a Document (which isn't a wrapped node), its `backend_doc`. Lets a
    # walker rooted at the document descend into its children.
    def backend_node_of(node)
      if node.respond_to?(:__dommy_backend_node__)
        node.__dommy_backend_node__
      elsif node.respond_to?(:backend_doc)
        node.backend_doc
      end
    end

    # Wrap the first Nokogiri node in `list` that has a wrapper, skipping ones
    # that don't (e.g. the DTD, which Dommy doesn't model as a child node).
    def first_wrappable(list, ctx)
      list.each do |nk|
        w = document_for(ctx).wrap_node(nk)
        return w if w
      end
      nil
    end

    def first_wrapped_child(node)
      bn = backend_node_of(node)
      bn ? first_wrappable(bn.children, node) : nil
    end

    def last_wrapped_child(node)
      bn = backend_node_of(node)
      # `.to_a` first: Nokogiri's NodeSet has `#reverse`, Makiri's does not.
      bn ? first_wrappable(bn.children.to_a.reverse, node) : nil
    end

    def next_sibling_wrapped(node)
      n = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__.next : nil
      n = n.next while n && document_for(node).wrap_node(n).nil?
      n && document_for(node).wrap_node(n)
    end

    def previous_sibling_wrapped(node)
      n = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__.previous : nil
      n = n.previous while n && document_for(node).wrap_node(n).nil?
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

    # WHATWG "traverse" (direction=next). referenceNode / pointerBeforeReferenceNode
    # are committed only when a node is accepted; if no node matches we return null
    # and leave the iterator's position untouched.
    def next_node
      node = @reference_node
      before = @pointer_before_reference
      loop do
        if before
          before = false
        else
          node = next_in_document_order(node)
          return nil unless node
        end

        next unless accept(node) == NodeFilter::FILTER_ACCEPT

        @reference_node = node
        @pointer_before_reference = before
        return node
      end
    end

    # WHATWG "traverse" (direction=previous).
    def previous_node
      node = @reference_node
      before = @pointer_before_reference
      loop do
        if before
          node = previous_in_document_order(node)
          return nil unless node
        else
          before = true
        end

        next unless accept(node) == NodeFilter::FILTER_ACCEPT

        @reference_node = node
        @pointer_before_reference = before
        return node
      end
    end

    def detach
      nil
    end

    # WHATWG "NodeIterator pre-removing steps". `removed` is the wrapped node
    # about to be detached (still attached when this runs).
    def pre_remove(removed)
      # Terminate unless `removed` is in this iterator's collection and an
      # inclusive ancestor of the reference node: skip if it is an inclusive
      # ancestor of root (never in the collection) or not one of referenceNode.
      return if inclusive_ancestor?(removed, @root)
      return unless inclusive_ancestor?(removed, @reference_node)

      unless @pointer_before_reference
        @reference_node = tree_preceding(removed)
        return
      end

      following = tree_next_descendants(removed)
      if following
        @reference_node = following
        return
      end

      @reference_node = tree_preceding(removed)
      @pointer_before_reference = false
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
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[nextNode previousNode detach]
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

    # The backend node backing a wrapper — an element/leaf's
    # `__dommy_backend_node__`, or a Document's `backend_doc` — so an iterator
    # rooted at the document can descend into its children (doctype, root, …).
    def backend_node_of(node)
      if node.respond_to?(:__dommy_backend_node__)
        node.__dommy_backend_node__
      elsif node.respond_to?(:backend_doc)
        node.backend_doc
      end
    end

    def first_child_node(node)
      bn = backend_node_of(node)
      n = bn&.children&.first
      n && document_for(node).wrap_node(n)
    end

    def last_child_node(node)
      bn = backend_node_of(node)
      n = bn&.children&.to_a&.last
      n && document_for(node).wrap_node(n)
    end

    def next_sibling_node(node)
      n = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__.next : nil
      n && document_for(node).wrap_node(n)
    end

    def previous_sibling_node(node)
      n = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__.previous : nil
      n && document_for(node).wrap_node(n)
    end

    def parent_node_of(node)
      parent_nk = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__.parent : nil
      return nil unless parent_nk

      # wrap_node maps the backend document node to the Dommy Document, so an
      # upward walk reaches the document root (traversal terminates on `== @root`).
      document_for(node).wrap_node(parent_nk)
    end

    def document_for(node)
      node.instance_variable_get(:@document) || @root.instance_variable_get(:@document) || @root
    end

    def same_node?(node_a, node_b)
      return false unless node_a && node_b
      return true if node_a.equal?(node_b)

      node_a.respond_to?(:__dommy_backend_node__) && node_b.respond_to?(:__dommy_backend_node__) &&
        node_a.__dommy_backend_node__.equal?(node_b.__dommy_backend_node__)
    end

    def inclusive_ancestor?(ancestor, descendant)
      current = descendant
      while current
        return true if same_node?(current, ancestor)

        current = parent_node_of(current)
      end
      false
    end

    # The last node preceding `node` in tree order (common.js `previousNode`).
    def tree_preceding(node)
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

    # The first node following `node` and all its descendants in tree order
    # (common.js `nextNodeDescendants`).
    def tree_next_descendants(node)
      node = parent_node_of(node) while node && next_sibling_node(node).nil?
      node && next_sibling_node(node)
    end
  end
end
