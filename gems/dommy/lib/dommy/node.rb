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

  # `RadioNodeList` — a NodeList a form's named getter returns when a name
  # matches more than one control. Adds `value`: the value of the checked radio
  # button in the list (or "" if none), and a setter that checks the radio whose
  # value matches.
  class RadioNodeList < NodeList
    # An optional `&compute` block makes the list LIVE: it re-evaluates the
    # membership on every DOM-shape read, so a reference held across a mutation
    # (e.g. removing a control from the group) reflects the change — matching the
    # form named getter's live RadioNodeList. Without a block it is a snapshot.
    def initialize(*args, &compute)
      @compute = compute
      super(*args, &nil) # the block is the live source, not Array.new's filler
    end

    # Refresh the backing storage from the live source, if any. Returns self so
    # it can prefix the Array reads below.
    def __internal_refresh__
      replace(@compute.call || []) if @compute
      self
    end

    def length
      __internal_refresh__
      super
    end

    def item(index)
      __internal_refresh__
      super
    end

    def [](index)
      __internal_refresh__
      super
    end

    def each(&block)
      __internal_refresh__
      super
    end

    def value
      __internal_refresh__
      radio = find { |el| radio_button?(el) && el.checked }
      radio ? radio.value.to_s : ""
    end

    # HTML: the first radio in the list whose value is the given one becomes
    # checked (its radio button group unchecks the rest); when there is none,
    # nothing changes.
    def value=(new_value)
      __internal_refresh__
      target = find { |el| radio_button?(el) && el.value.to_s == new_value.to_s }
      target.checked = true if target
      new_value
    end

    def __js_get__(key)
      return value if key == "value"

      super
    end

    def __js_set__(key, v)
      return self.value = v if key == "value"

      super
    end

    private

    def radio_button?(el)
      el.respond_to?(:type) && el.type.to_s.casecmp?("radio")
    end
  end

  # `LiveList` — the live, re-evaluating collection surface shared by
  # `LiveNodeList` (a NodeList) and `StyleSheetList`. The constructor takes a
  # block yielding the current array; `length`, `item` and iteration call it on
  # every access, so a mutation between reads is seen rather than a snapshot.
  #
  # A class rather than a module so `js_methods` / `js_method_names` compose
  # through `superclass` the way the bridge reads them; `DomInterfaces` maps it
  # to no interface (see NAME_OVERRIDES), so only the concrete subclasses appear
  # in an object's interface chain.
  class LiveList
    include Enumerable

    # `count` and `at` are an optional fast path for a list whose length
    # and nth item can be asked of the backend directly — a node's children
    # — so reading `length` or walking it by index (idiomorph, morphdom,
    # every framework that loops `childNodes[i]`) wraps the one item asked
    # for rather than building the whole list each step.
    def initialize(count: nil, at: nil, &block)
      @compute = block
      @count = count
      @at = at
    end

    def length
      @count ? @count.call : @compute.call.length
    end

    alias size length

    def item(index)
      i = index.to_i
      return nil if i.negative?
      return @at.call(i) if @at

      arr = @compute.call
      return nil if i >= arr.length

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

  # `LiveNodeList` — like NodeList, but re-evaluates its source on every access.
  # Returned by APIs whose spec says "live" — e.g. `Node.childNodes`.
  class LiveNodeList < LiveList
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

    # The backend (makiri) node behind this one, or nil for the nodes that
    # sit in no backend tree: a Document, an Attr, a synthetic DocumentType.
    # The node classes that have one override it.
    def __dommy_backend_node__ = nil

    # WHATWG Node.isEqualNode — deep structural equality (type-specific data
    # plus equal, in-order, recursively-equal children). Available on every node
    # class that includes Node; the bridge routes "isEqualNode" here.
    def is_equal_node(other)
      Internal::NodeEquality.equal?(self, other)
    end

    # WHATWG Node.ownerDocument — null when this is a document, this node's
    # node document otherwise. The IDL puts the attribute on Node, so every node
    # class needs it; only Element and Attr defined it before, which left
    # Text, Comment, ProcessingInstruction, CDATASection, DocumentFragment and
    # DocumentType without one.
    def owner_document
      return nil if is_a?(Dommy::Document)

      document
    end

    # Node.isSameNode — strict reference identity (deprecated alias for `===`).
    def is_same_node(other)
      equal?(other)
    end

    # Re-bind this wrapper onto `backend_node`, now owned by `document` — the
    # last step of a cross-document adopt. A backend that cannot move a node
    # between its documents (Makiri: they are separate arenas) hands back an
    # imported copy instead, and the WRAPPER has to survive the move, because
    # `destination.adoptNode(x)` must still be `x` to the page script holding it.
    #
    # It lives on the node rather than in the adopter because only the node
    # class knows everything bound to the node it wraps: a DocumentType also
    # remembers the document it was created with, and nothing outside it should
    # have to know that.
    def __internal_reseat__(backend_node, document)
      @__node__ = backend_node
      @document = document
      nil
    end

    # Node.compareDocumentPosition(other) — a bitmask describing where `other`
    # sits relative to this node: 0 for the same node, CONTAINS/CONTAINED_BY for
    # ancestor/descendant, PRECEDING/FOLLOWING for tree order, or DISCONNECTED
    # (with IMPLEMENTATION_SPECIFIC and a consistent direction) for unrelated
    # nodes. An Attr stands at its element, before the element's children: two
    # attributes of one element compare in attribute-list order, and an
    # element contains its own attributes.
    # Spec: https://dom.spec.whatwg.org/#dom-node-comparedocumentposition
    def compare_document_position(other)
      return 0 if equal?(other)

      attr1 = other if other.is_a?(Attr)
      attr2 = self if is_a?(Attr)
      node1 = attr1 ? attr1.owner_element : other
      node2 = attr2 ? attr2.owner_element : self
      if attr1 && attr2 && node1 && node1.equal?(node2)
        return DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC | attribute_order(node2, attr1, attr2)
      end

      self_node = node2 && compare_backend_node(node2)
      other_node = node1 && compare_backend_node(node1)
      return disconnected_position(other, self_node, other_node) unless self_node && other_node

      if self_node == other_node
        # One of the two is an attribute of the other.
        return attr2 ? DOCUMENT_POSITION_CONTAINS | DOCUMENT_POSITION_PRECEDING : DOCUMENT_POSITION_CONTAINED_BY | DOCUMENT_POSITION_FOLLOWING
      end

      self_ancestors = node_ancestor_chain(self_node)
      other_ancestors = node_ancestor_chain(other_node)

      common = self_ancestors.find { |a| other_ancestors.include?(a) }
      return disconnected_position(other, self_node, other_node) unless common
      # An attribute of an ancestor is no ancestor: it precedes, as its
      # element does, and one of a descendant follows.
      if common == self_node
        return attr2 ? DOCUMENT_POSITION_FOLLOWING : DOCUMENT_POSITION_CONTAINED_BY | DOCUMENT_POSITION_FOLLOWING
      end
      if common == other_node
        return attr1 ? DOCUMENT_POSITION_PRECEDING : DOCUMENT_POSITION_CONTAINS | DOCUMENT_POSITION_PRECEDING
      end

      self_branch = node_branch_under(common, self_ancestors)
      other_branch = node_branch_under(common, other_ancestors)
      common.children.each do |child|
        return DOCUMENT_POSITION_FOLLOWING if child == self_branch
        return DOCUMENT_POSITION_PRECEDING if child == other_branch
      end
      disconnected_position(other, self_node, other_node)
    end

    # Node.getRootNode — the topmost ancestor of this node (the document, a
    # ShadowRoot, a detached subtree root, or the node itself). Generic default
    # for any node backed by a Nokogiri node; classes with special roots
    # (Element's shadow handling) override it. `{composed: true}` asks for the
    # shadow-including root, so a shadow root hands over to its host's.
    def get_root_node(options = nil)
      node = __dommy_backend_node__
      return self unless node && instance_variable_defined?(:@document)

      node = Internal::NodeTraversal.root_of(node)
      # The topmost node of an attached subtree is the Nokogiri document, which
      # has no element wrapper — map it to the Document. A detached node's root is
      # itself.
      return @document if @document && node.equal?(@document.backend_doc)

      root = (@document && @document.wrap_node(node)) || self
      return root unless root.is_a?(ShadowRoot) && Node.composed_option?(options)

      root.host.get_root_node(options)
    end

    # `getRootNode(options)`'s `composed` member, read with JS truthiness.
    def self.composed_option?(options)
      options.is_a?(Hash) &&
        EventTarget.js_truthy?(options.key?("composed") ? options["composed"] : options[:composed])
    end

    # Node.normalize() — a node with no descendants has no Text run to merge.
    # ParentNode and Document override it.
    def normalize
      nil
    end

    HTML_NAMESPACE = Internal::Namespaces::HTML
    XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
    XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

    # Node.lookupNamespaceURI(prefix) — WHATWG "locate a namespace": walk from the
    # nearest enclosing element up its ancestors, matching the element's own
    # namespace (by prefix) and its xmlns declarations. `xml` / `xmlns` are
    # implicitly bound. Non-element scopes (fragment, doctype, disconnected attr)
    # locate nothing.
    def lookup_namespace_uri(prefix)
      wanted = namespace_prefix_arg(prefix)
      el = starting_namespace_element
      return nil unless el
      return XML_NAMESPACE if wanted == "xml"
      return XMLNS_NAMESPACE if wanted == "xmlns"

      each_namespace_ancestor(el) do |node|
        ns = node.namespace_uri
        return ns if ns && !ns.to_s.empty? && wrapper_prefix(node) == wanted

        node.attributes.each do |attr|
          next unless attr.namespace_uri == XMLNS_NAMESPACE

          ap = normalize_ns_prefix(attr.__js_get__("prefix"))
          value = attr.value.to_s
          if ap == "xmlns" && attr.local_name == wanted
            return value.empty? ? nil : value
          elsif ap.nil? && attr.local_name == "xmlns" && wanted.nil?
            return value.empty? ? nil : value
          end
        end
      end
      nil
    end

    # Node.lookupPrefix(namespace) — WHATWG "locate a prefix": a prefix bound to
    # `namespace` in this node's scope, or null.
    def lookup_prefix(namespace)
      ns = namespace.to_s
      return nil if ns.empty?

      el = starting_namespace_element
      return nil unless el

      each_namespace_ancestor(el) do |node|
        return wrapper_prefix(node) if node.namespace_uri == ns && wrapper_prefix(node)

        node.attributes.each do |attr|
          next unless attr.namespace_uri == XMLNS_NAMESPACE
          next unless normalize_ns_prefix(attr.__js_get__("prefix")) == "xmlns"

          return attr.local_name if attr.value.to_s == ns
        end
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

    # The backend node to position `obj` by. A Document's
    # `__dommy_backend_node__` is nil — it sits in no backend tree as a node —
    # but for tree-position purposes it stands in for its backend document node,
    # so `document.compareDocumentPosition(child)` works. Anything without a
    # backend node is disconnected (nil).
    def compare_backend_node(obj)
      return obj.backend_doc if obj.is_a?(Dommy::Document)

      obj.__dommy_backend_node__ if obj.is_a?(Node)
    end

    # Where `other_attr` stands from `self_attr`, two attributes of `element`:
    # PRECEDING when it comes first in the attribute list, else FOLLOWING.
    def attribute_order(element, other_attr, self_attr)
      element.attributes.each do |attr|
        return DOCUMENT_POSITION_PRECEDING if attr.equal?(other_attr)
        return DOCUMENT_POSITION_FOLLOWING if attr.equal?(self_attr)
      end
      DOCUMENT_POSITION_FOLLOWING
    end

    # Nodes in different trees compare in an order the standard leaves to the
    # implementation, but it has to be an order: the same answer every time, and
    # opposite directions for the two argument orders. Sorting the pair by a
    # stable per-node key gives that, so one side reports PRECEDING and the other
    # FOLLOWING instead of both claiming PRECEDING.
    def disconnected_position(other, self_node, other_node)
      direction =
        if (disconnected_order_key(self, self_node) <=> disconnected_order_key(other, other_node)).negative?
          DOCUMENT_POSITION_FOLLOWING
        else
          DOCUMENT_POSITION_PRECEDING
        end
      DOCUMENT_POSITION_DISCONNECTED | DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC | direction
    end

    # The sort key behind that order. A backend node's identity key is its
    # address, which Makiri never recycles for a live node; an Attr and anything
    # else without a backend node falls back to its wrapper's identity, which
    # orders it just as consistently. The wrapper's id also breaks a tie between
    # two keys drawn from those two different spaces — `equal?` has already
    # answered for one node against itself, so distinct nodes never tie on both.
    def disconnected_order_key(wrapper, node)
      [node ? Backend.identity_key(node) : 0, wrapper.object_id]
    end

    # The backend-node chain from `node` up to and INCLUDING the document node.
    # Unlike NodeTraversal.each_ancestor (which stops before the document), this
    # keeps the document so that two of its direct children — e.g. the doctype and
    # the documentElement — share it as their common ancestor and compare in tree
    # order rather than reporting DISCONNECTED.
    def node_ancestor_chain(node)
      chain = [node]
      current = node
      while (current = current.parent)
        chain << current
      end
      chain
    end

    def node_branch_under(common, chain)
      chain.each_with_index do |node, i|
        return node if i.zero? && node == common
        return node if node.parent == common
      end
      nil
    end

    def namespace_prefix_arg(prefix)
      return nil if prefix.nil? || prefix.to_s.empty?
      return nil if defined?(Bridge::UNDEFINED) && prefix.equal?(Bridge::UNDEFINED)

      prefix.to_s
    end

    def normalize_ns_prefix(prefix)
      return nil if prefix.nil? || prefix.to_s.empty?
      return nil if defined?(Bridge::UNDEFINED) && prefix.equal?(Bridge::UNDEFINED)

      prefix.to_s
    end

    # The nearest enclosing element (as a Dommy wrapper) to start a namespace
    # locate from: the element itself, a character-data/child node's ancestor
    # element, an attr's owner element, or the document element. A fragment,
    # doctype, or disconnected node has none.
    def starting_namespace_element
      node = self
      node = node.owner_element if node.respond_to?(:owner_element) # Attr
      return nil unless node
      node = node.document_element if node.respond_to?(:document_element) # Document

      while node && !namespace_element?(node)
        node = node.respond_to?(:parent_node) ? node.parent_node : nil
      end
      node
    end

    def namespace_element?(node) = node.is_a?(Element)

    # Yield `el` and each of its ancestor elements (Dommy wrappers) in turn.
    def each_namespace_ancestor(el)
      doc = el.document
      while el
        yield el
        parent = el.__dommy_backend_node__.parent
        el = parent&.element? ? doc.wrap_node(parent) : nil
      end
    end

    # An element wrapper's prefix (nil when unprefixed).
    def wrapper_prefix(node)
      normalize_ns_prefix(node.__js_get__("prefix"))
    end
  end
end

require_relative "internal/node_equality"
