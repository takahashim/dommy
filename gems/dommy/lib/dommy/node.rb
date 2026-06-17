# frozen_string_literal: true

module Dommy
  # `NodeList` — Array sub-class that adds the DOM NodeList surface
  # (`item(i)` / `forEach(cb)` / `entries` / `keys` / `values`) on
  # top of regular Array operations. Returned from
  # `querySelectorAll`, `getElementsBy*`, `childNodes`, etc.
  #
  # Live vs. static collections aren't distinguished here — Dommy
  # snapshots tree state at the time of the query, matching what
  # most happy-dom test patterns expect.
  class NodeList < Array
    # Spec-compliant: out-of-range returns nil, not raise (Array#[] is
    # close but we make negative indices fail too — DOM `item(-1)` is
    # nil, not Array#[-1]'s last element).
    def item(index)
      i = index.to_i
      return nil if i < 0 || i >= length

      self[i]
    end

    # Spec signature: `forEach(callback(value, key, listObj))`. The
    # Ruby `each_with_index` block-arg order is (value, index), which
    # we re-yield as (value, index, self) for spec parity.
    def for_each(&block)
      each_with_index do |value, index|
        block.call(value, index, self)
      end

      nil
    end

    alias forEach for_each

    # NodeList `entries` returns an enumerator of [index, value].
    def entries
      each_with_index.map { |value, index| [index, value] }
    end

    def keys
      (0...length).to_a
    end

    # `values` is the iterator of the NodeList itself; we return
    # `self.to_a` (a plain Array copy) so callers can't mutate
    # the original list.
    def values
      to_a
    end

    def __js_get__(key)
      case key
      when "length"
        length
      else
        # Indexed getter: out-of-range yields JS `undefined` (item() returns null).
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          token = item(key.to_i)
          token.nil? ? Bridge::UNDEFINED : token
        else
          Bridge::ABSENT # unknown non-index property
        end
      end
    end

    include Bridge::Methods
    # forEach/keys/values/entries/Symbol.iterator come from the array-like
    # prototype JS-side (the actual %Array.prototype% functions) — see NodeList
    # and host_runtime.js. A host `forEach` would shadow that and break the call
    # (a JS callback arrives as a HostCallback, not a block). Only `item` needs a
    # host method.
    js_methods %w[item]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      end
    end
  end

  # `LiveNodeList` — like NodeList, but re-evaluates its source on
  # every access. Returned by APIs whose spec says "live" — e.g.
  # `Node.childNodes`. The constructor takes a block that yields the
  # current array of nodes; `length`, `item`, iteration all call it.
  #
  # Inherits Array so `list[i]` / `list.each` still work for callers
  # that don't know about the live semantics, but those work off a
  # snapshot taken at the moment of the call. The DOM-shape methods
  # (`length`, `item`, `for_each`) re-query on every call.
  class LiveNodeList
    include Enumerable

    def initialize(&block)
      @compute = block
    end

    def length
      @compute.call.length
    end

    alias size length

    def item(index)
      i = index.to_i
      arr = @compute.call
      return nil if i < 0 || i >= arr.length

      arr[i]
    end

    def [](index)
      case index
      when Integer
        item(index)
      else
        nil
      end
    end

    def first
      @compute.call.first
    end

    def last
      @compute.call.last
    end

    def each(&block)
      @compute.call.each(&block)
      self
    end

    def to_a
      @compute.call.dup
    end

    def for_each(&block)
      @compute.call.each_with_index do |value, index|
        block.call(value, index, self)
      end

      nil
    end

    alias forEach for_each

    def entries
      @compute.call.each_with_index.map { |v, i| [i, v] }
    end

    def keys
      (0...length).to_a
    end

    def values
      to_a
    end

    def empty?
      @compute.call.empty?
    end

    def __js_get__(key)
      case key
      when "length"
        length
      else
        # Indexed getter: out-of-range yields JS `undefined` (item() returns null).
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          token = item(key.to_i)
          token.nil? ? Bridge::UNDEFINED : token
        else
          Bridge::ABSENT # unknown non-index property
        end
      end
    end

    include Bridge::Methods
    # forEach/keys/values/entries/Symbol.iterator are provided JS-side (the
    # array-like prototype is seeded with the actual %Array.prototype% functions)
    # so `list.forEach === Array.prototype.forEach` and they return real
    # iterators, not arrays — see host_runtime.js. Exposing a host `forEach` here
    # would shadow that prototype copy (and a JS callback reaches Ruby as a
    # HostCallback, not a block). Only `item` needs a host method.
    js_methods %w[item]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      end
    end
  end

  # `Node` — common base mixin. All node-like classes (Element,
  # TextNode, CommentNode, CharacterDataNode, Document, Fragment,
  # DocumentType, ShadowRoot) include this so `el.is_a?(Dommy::Node)`
  # works.
  #
  # Real classes already define `nodeType` / `nodeName` / `nodeValue`
  # / `parentNode` / `isConnected` / `cloneNode` independently; this
  # module is primarily an identity marker. Adding new shared methods
  # later is straightforward.
  module Node
    # Standardized nodeType constants — duplicated from Element so
    # callers can refer to `Dommy::Node::ELEMENT_NODE` without
    # depending on a specific subclass.
    ELEMENT_NODE = 1
    ATTRIBUTE_NODE = 2
    TEXT_NODE = 3
    CDATA_SECTION_NODE = 4
    PROCESSING_INSTRUCTION_NODE = 7
    COMMENT_NODE = 8
    DOCUMENT_NODE = 9
    DOCUMENT_TYPE_NODE = 10
    DOCUMENT_FRAGMENT_NODE = 11

    DOCUMENT_POSITION_DISCONNECTED = 0x01
    DOCUMENT_POSITION_PRECEDING = 0x02
    DOCUMENT_POSITION_FOLLOWING = 0x04
    DOCUMENT_POSITION_CONTAINS = 0x08
    DOCUMENT_POSITION_CONTAINED_BY = 0x10
    DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC = 0x20

    # WHATWG Node.isEqualNode — deep structural equality (type-specific data
    # plus equal, in-order, recursively-equal children). Available on every node
    # class that includes Node; the bridge routes "isEqualNode" here.
    def is_equal_node(other)
      Internal::NodeEquality.equal?(self, other)
    end

    # Node.isSameNode — strict reference identity (deprecated alias for `===`).
    def is_same_node(other)
      equal?(other)
    end

    # Node.compareDocumentPosition(other) — a bitmask describing where `other`
    # sits relative to this node: 0 for the same node, CONTAINS/CONTAINED_BY for
    # ancestor/descendant, PRECEDING/FOLLOWING for tree order, or DISCONNECTED
    # (with a stable IMPLEMENTATION_SPECIFIC|PRECEDING) for unrelated nodes.
    # Generic over any node with a backing Nokogiri node.
    def compare_document_position(other)
      return 0 if equal?(other)
      unless respond_to?(:__dommy_backend_node__) && other.respond_to?(:__dommy_backend_node__)
        return DOCUMENT_POSITION_DISCONNECTED | DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC | DOCUMENT_POSITION_PRECEDING
      end

      self_node = __dommy_backend_node__
      other_node = other.__dommy_backend_node__
      self_ancestors = node_ancestor_chain(self_node)
      other_ancestors = node_ancestor_chain(other_node)

      common = self_ancestors.find { |a| other_ancestors.include?(a) }
      unless common
        return DOCUMENT_POSITION_DISCONNECTED | DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC | DOCUMENT_POSITION_PRECEDING
      end
      return DOCUMENT_POSITION_CONTAINED_BY | DOCUMENT_POSITION_FOLLOWING if common == self_node
      return DOCUMENT_POSITION_CONTAINS | DOCUMENT_POSITION_PRECEDING if common == other_node

      self_branch = node_branch_under(common, self_ancestors)
      other_branch = node_branch_under(common, other_ancestors)
      common.children.each do |child|
        return DOCUMENT_POSITION_FOLLOWING if child == self_branch
        return DOCUMENT_POSITION_PRECEDING if child == other_branch
      end
      DOCUMENT_POSITION_DISCONNECTED
    end

    # Node.getRootNode — the topmost ancestor of this node (the document, a
    # ShadowRoot, a detached subtree root, or the node itself). Generic default
    # for any node backed by a Nokogiri node; classes with special roots
    # (Element's shadow handling) override it.
    def get_root_node(_options = nil)
      return self unless respond_to?(:__dommy_backend_node__) && instance_variable_defined?(:@document)

      node = __dommy_backend_node__
      node = node.parent while node.respond_to?(:parent) && node.parent
      # The topmost node of an attached subtree is the Nokogiri document, which
      # has no element wrapper — map it to the Document. A detached node's root is
      # itself.
      return @document if @document && node.equal?(@document.backend_doc)

      (@document && @document.wrap_node(node)) || self
    end

    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"

    # Node.lookupNamespaceURI(prefix) — the namespace bound to `prefix` (or the
    # default namespace for a null/empty prefix) in this node's scope, walking up
    # the element ancestors' namespace declarations. HTML elements default to the
    # XHTML namespace.
    def lookup_namespace_uri(prefix)
      wanted = namespace_prefix_arg(prefix)
      nk = nearest_namespaceable_node
      while nk.respond_to?(:element?) && nk.element?
        Backend.namespace_definitions(nk).each do |d|
          return d.href if normalize_ns_prefix(d.prefix) == wanted
        end
        if wanted.nil?
          ns = Backend.namespace_of(nk)
          return ns ? ns.href : HTML_NAMESPACE
        end

        nk = nk.parent
      end
      nil
    end

    # Node.lookupPrefix(namespace) — a prefix bound to `namespace`, or null for
    # the default namespace.
    def lookup_prefix(namespace)
      ns = namespace.to_s
      return nil if ns.empty?

      nk = nearest_namespaceable_node
      while nk.respond_to?(:element?) && nk.element?
        Backend.namespace_definitions(nk).each do |d|
          return d.prefix if d.href == ns && d.prefix
        end
        nk = nk.parent
      end
      nil
    end

    # Node.isDefaultNamespace(namespace) — true if `namespace` (null/"" → null) is
    # the default namespace in this node's scope.
    def is_default_namespace(namespace)
      ns = namespace.nil? ? nil : namespace.to_s
      ns = nil if ns == ""
      lookup_namespace_uri(nil) == ns
    end

    private

    def node_ancestor_chain(node)
      chain = [node]
      Internal::NodeTraversal.each_ancestor(node) { |n| chain << n }
      chain
    end

    def node_branch_under(common, chain)
      chain.each_with_index do |node, i|
        return node if i.zero? && node == common
        return node if node.respond_to?(:parent) && node.parent == common
      end
      nil
    end

    def namespace_prefix_arg(prefix)
      return nil if prefix.nil? || prefix.to_s.empty?
      return nil if defined?(Bridge::UNDEFINED) && prefix.equal?(Bridge::UNDEFINED)

      prefix.to_s
    end

    def normalize_ns_prefix(prefix)
      prefix.nil? || prefix.to_s.empty? ? nil : prefix.to_s
    end

    def nearest_namespaceable_node
      return nil unless respond_to?(:__dommy_backend_node__)

      nk = __dommy_backend_node__
      nk = nk.parent while nk.respond_to?(:element?) && !nk.element? && nk.respond_to?(:parent) && nk.parent
      nk
    end
  end
end

require_relative "internal/node_equality"
