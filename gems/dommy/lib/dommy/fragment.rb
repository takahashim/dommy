# frozen_string_literal: true

module Dommy
  # DocumentFragment: a parentless container the DOM moves children
  # through.
  #
  # Lived in element.rb, which is for Element.
  class Fragment
    include EventTarget
    include Node
    include Internal::ParentNode

    attr_reader :document

    def __dommy_backend_node__ = @__node__

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
    end

    # Public Ruby API (DocumentFragment surface)

    # Node.cloneNode: a fresh, empty fragment, and — when `deep` — a clone of
    # each child appended in tree order ("clone a node" step 5). Cloning the
    # children one by one rather than re-parsing the fragment's serialization
    # keeps each of them its own interface: a comment stays a comment, and a
    # processing instruction does not come back as one.
    def clone_node(deep = false)
      copy = @document.create_document_fragment
      return copy unless deep

      child_nodes.each { |child| copy.append_child(child.clone_node(true)) }
      copy
    end

    # `children` is a [SameObject] live HTMLCollection (as on Element); the
    # collection's block re-runs on every access, so it tracks mutations while
    # `fragment.children === fragment.children` holds.
    def children
      @live_children ||= HTMLCollection.new do
        @__node__.element_children.each_with_object([]) do |node, out|
          wrapped = @document.wrap_node(node)
          out << wrapped if wrapped
        end
      end
    end

    def child_element_count
      @__node__.element_children.size
    end

    # Live, cached childNodes so `fragment.childNodes === fragment.childNodes` and
    # later mutations are reflected (WHATWG live NodeList).
    def child_nodes
      @live_child_nodes ||= LiveNodeList.new do
        @__node__.children.map { |n| @document.wrap_node(n) }.compact
      end
    end

    def first_child
      @document.wrap_node(@__node__.children.first)
    end

    def last_child
      @document.wrap_node(@__node__.children.last)
    end

    def first_element_child
      @document.wrap_node(@__node__.children.find(&:element?))
    end

    def last_element_child
      @document.wrap_node(@__node__.element_children.last)
    end

    def text_content
      @__node__.text
    end

    def text_content=(value)
      # WHATWG "string replace all": one logical operation, so one childList
      # record covering both sides — and an empty (or null / undefined) value
      # leaves no children at all rather than an empty Text node.
      string_replace_all(value)
    end

    def __js_set__(key, value)
      case key
      when "textContent"
        self.text_content = value
        nil
      else
        Bridge::UNHANDLED
      end
    end

    def query_selector(selector)
      return nil if selector.nil?
      ast = Internal::SelectorParser.parse!(selector)
      Internal::SelectorMatcher.query_first(self, ast, scope: self)
    end

    def query_selector_all(selector)
      return NodeList.new if selector.nil?
      ast = Internal::SelectorParser.parse!(selector)
      NodeList.new(Internal::SelectorMatcher.query(self, ast, scope: self))
    end

    def get_element_by_id(id)
      return nil if id.nil? || id.to_s.empty?

      # getElementById matches the `id` attribute literally, not as a CSS
      # selector, so escape special characters (e.g. React `useId` `:rjm:`) to a
      # valid id-selector ident — a raw "##{id}" would be an invalid selector.
      @document.wrap_node(@__node__.at_css("##{Dommy::CSSNamespace.escape(id)}"))
    end

    def __js_get__(key)
      case key
      when "nodeType"
        11
      when "nodeName"
        "#document-fragment"
      when "nodeValue"
        # A DocumentFragment's nodeValue is null (not undefined).
        nil
      when "children"
        children
      when "childNodes"
        child_nodes
      when "childElementCount"
        child_element_count
      when "isConnected"
        is_connected?
      when "firstChild"
        first_child
      when "lastChild"
        last_child
      when "firstElementChild"
        first_element_child
      when "lastElementChild"
        last_element_child
      when "textContent"
        @__node__.text
      when "parentNode", "parentElement"
        # A DocumentFragment is never inserted, so it has no parent (null, not
        # undefined).
        nil
      when "ownerDocument"
        @document
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[cloneNode querySelector querySelectorAll getElementById appendChild isEqualNode hasChildNodes
      append prepend replaceChildren moveBefore removeChild insertBefore replaceChild
      isSameNode getRootNode contains normalize compareDocumentPosition
      lookupNamespaceURI lookupPrefix isDefaultNamespace
      addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "hasChildNodes"
        @__node__.children.any?
      when "compareDocumentPosition"
        compare_document_position(args[0])
      when "lookupNamespaceURI"
        lookup_namespace_uri(args[0])
      when "lookupPrefix"
        lookup_prefix(args[0])
      when "isDefaultNamespace"
        is_default_namespace(args[0])
      when "cloneNode"
        clone_node(args.first)
      when "querySelector"
        query_selector(Internal.css_query_arg!(args))
      when "querySelectorAll"
        query_selector_all(Internal.css_query_arg!(args))
      when "getElementById"
        get_element_by_id(args[0])
      when "appendChild"
        append_child(args[0])
      when "append"
        append(*args)
      when "prepend"
        prepend(*args)
      when "replaceChildren"
        replace_children(*args)
      when "moveBefore"
        raise Bridge::TypeError, "moveBefore requires 2 arguments." if args.length < 2

        move_before(args[0], args[1])
        Bridge::UNDEFINED
      when "removeChild"
        remove_child(args[0])
      when "insertBefore"
        validate_insert_before_ref!(args)
        insert_before(args[0], args[1])
      when "replaceChild"
        replace_child(args[0], args[1])
      when "isEqualNode"
        is_equal_node(args[0])
      when "isSameNode"
        is_same_node(args[0])
      when "getRootNode"
        get_root_node(args[0])
      when "contains"
        contains?(args[0])
      when "normalize"
        normalize
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      else
        nil
      end
    end

    def extract_children
      nodes = @__node__.children.to_a
      return nodes if nodes.empty?

      nodes.each { |n| @document.detach_node(n) }
      # Inserting a DocumentFragment removes all its children first; the spec
      # queues a single childList record on the fragment for that removal.
      @document.notify_child_list_mutation(target_node: @__node__, added_nodes: [], removed_nodes: nodes)
      nodes
    end

    # Node mutation on the fragment's children (ParentNode covers append/prepend/
    # replaceChildren; these are the remaining Node methods).
    def remove_child(node)
      bn = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
      raise DOMException::NotFoundError, "node is not a child of this fragment" unless bn && bn.parent == @__node__

      # `remove_node_with_notify`, not the bare `detach_node`: WHATWG remove
      # step 21 queues a childList record on the parent, and a fragment is a
      # parent like any other — an observer registered on it must see this.
      @document.remove_node_with_notify(bn)
      node
    end

    def insert_before(node, ref)
      Internal::WebIDL.node!(node)
      ensure_pre_insertion_validity!(node, ref)
      ref_bn = ref.respond_to?(:__dommy_backend_node__) ? ref.__dommy_backend_node__ : nil
      ref_bn = nil unless ref_bn && ref_bn.parent == @__node__
      ref_bn = Internal::InsertionPoint.skip_args(ref_bn, backend_nodes_in([node]))
      # Insert step 6's insertion point, taken before the conversion detaches
      # anything, and step 9's record. A fragment is a parent like any other:
      # an observer registered on it must see the insertion.
      record_previous = insertion_previous_sibling(@__node__, ref_bn)
      record_next = wrap_sibling(ref_bn)
      nodes = convert_for_insert([node], @__node__, ref_bn)
      ref_bn = nil if ref_bn && ref_bn.parent != @__node__
      if ref_bn
        nodes.each { |n| ref_bn.add_previous_sibling(n) }
      else
        nodes.each { |n| @__node__.add_child(n) }
      end
      notify_child_list(added: nodes, previous_sibling: record_previous,
                        next_sibling: record_next)
      node
    end

    def replace_child(new_child, old_child)
      Internal::WebIDL.node!(new_child)
      # WHATWG "replace" step 1 runs the full ensure-pre-insertion-validity,
      # whose step 2 (node is an inclusive ancestor of parent — a cycle) comes
      # BEFORE step 3 (the reference child's parentage). So
      # `frag.replaceChild(frag, frag)` is a HierarchyRequestError, not the
      # NotFoundError an up-front parentage guard would raise.
      ensure_pre_insertion_validity!(new_child, old_child)
      old_bn = old_child.respond_to?(:__dommy_backend_node__) ? old_child.__dommy_backend_node__ : nil
      raise DOMException::NotFoundError, "node is not a child of this fragment" unless old_bn && old_bn.parent == @__node__

      replace_child_within(new_child, old_bn)
      old_child
    end

    def contains?(other)
      return false unless other.respond_to?(:__dommy_backend_node__)

      on = other.__dommy_backend_node__
      # Walk parents rather than the backend's `ancestors`: Makiri omits a
      # DocumentFragment parent from `ancestors`, so a fragment never appears
      # to contain its own children. `parent` is consistent across backends.
      on == @__node__ || Internal::NodeTraversal.ancestor_of?(@__node__, on)
    end

    # A bare DocumentFragment is never connected — its shadow-including root is
    # itself, not a document. (A ShadowRoot is a fragment too, but has its own
    # host-following answer.) Beyond `node.isConnected`, this is what tells the
    # mutation pipeline to skip the connected/disconnected walk for mutations
    # inside a detached fragment: a custom element parsed into a `<template>`'s
    # content must NOT get a connectedCallback there, only when it is later
    # inserted into a document.
    def is_connected?
      false
    end

    alias connected? is_connected?

    private

    # Fragments aren't part of the bubble chain; nil terminates
    # bubbling at the boundary (shadow root, detached fragment, etc.).
    def __internal_event_parent__
      nil
    end
  end

  # CharacterData base — TextNode and CommentNode share the data /
  # nodeValue / textContent API and `remove` / `cloneNode` semantics.
end
