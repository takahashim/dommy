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
      super(*args)
    end

    # Refresh the backing storage from the live source, if any. Returns self so
    # it can prefix the Array reads below.
    def __refresh__
      replace(@compute.call || []) if @compute
      self
    end

    def length
      __refresh__
      super
    end

    def item(index)
      __refresh__
      super
    end

    def [](index)
      __refresh__
      super
    end

    def each(&block)
      __refresh__
      super
    end

    def value
      __refresh__
      radio = find { |el| radio_button?(el) && el.checked }
      radio ? radio.value.to_s : ""
    end

    def value=(new_value)
      __refresh__
      target = find { |el| radio_button?(el) && el.value.to_s == new_value.to_s }
      each { |el| el.checked = false if radio_button?(el) }
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

      self_node = compare_backend_node(self)
      other_node = compare_backend_node(other)
      unless self_node && other_node
        return DOCUMENT_POSITION_DISCONNECTED | DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC | DOCUMENT_POSITION_PRECEDING
      end

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

    # The backend node to position `obj` by. A Document has no
    # `__dommy_backend_node__` (it must not, or 60-odd `respond_to?` guards would
    # misclassify it as a plain node), but for tree-position purposes it stands in
    # for its backend document node — so `document.compareDocumentPosition(child)`
    # works. Anything without a backend node is disconnected (nil).
    def compare_backend_node(obj)
      return obj.__dommy_backend_node__ if obj.respond_to?(:__dommy_backend_node__)

      obj.backend_doc if obj.is_a?(Dommy::Document)
    end

    # The backend-node chain from `node` up to and INCLUDING the document node.
    # Unlike NodeTraversal.each_ancestor (which stops before the document), this
    # keeps the document so that two of its direct children — e.g. the doctype and
    # the documentElement — share it as their common ancestor and compare in tree
    # order rather than reporting DISCONNECTED.
    def node_ancestor_chain(node)
      chain = [node]
      current = node
      while current.respond_to?(:parent) && (current = current.parent)
        chain << current
      end
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

    def namespace_element?(node)
      node.respond_to?(:attributes) && node.respond_to?(:namespace_uri) &&
        node.respond_to?(:__dommy_backend_node__) &&
        node.__dommy_backend_node__.respond_to?(:element?) &&
        node.__dommy_backend_node__.element?
    end

    # Yield `el` and each of its ancestor elements (Dommy wrappers) in turn.
    def each_namespace_ancestor(el)
      doc = el.respond_to?(:document) ? el.document : nil
      while el
        yield el
        parent = el.__dommy_backend_node__.parent
        el = parent && parent.respond_to?(:element?) && parent.element? && doc ? doc.wrap_node(parent) : nil
      end
    end

    # An element wrapper's prefix (nil when unprefixed).
    def wrapper_prefix(node)
      normalize_ns_prefix(node.__js_get__("prefix"))
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
