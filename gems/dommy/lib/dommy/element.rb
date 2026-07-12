# frozen_string_literal: true

require "uri"

require_relative "parser"

module Dommy
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

    def children
      element_children
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
      # Replace all children with a single Text node (nullable: null/undefined
      # clear with no replacement). Unlink old children so a removed node keeps
      # its own descendants.
      removed = @__node__.children.to_a
      str = nullable_dom_string(value)
      removed.each(&:unlink)
      @__node__.add_child(@document.create_text_node(str).__dommy_backend_node__) unless str.empty?
      notify_child_list(added: @__node__.children.to_a, removed: removed)
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
        element_children
      when "childNodes"
        child_nodes
      when "childElementCount"
        child_element_count
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
      append prepend replaceChildren removeChild insertBefore replaceChild
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
        deep = args.empty? ? false : !!args[0]
        deep ? @document.wrap_node(Parser.fragment(@__node__.to_html, owner_doc: @document.backend_doc)) : @document
          .wrap_node(Parser.fragment("", owner_doc: @document.backend_doc))
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

      nodes.each(&:unlink)
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

      bn.unlink
      node
    end

    def insert_before(node, ref)
      coerce_node_argument!(node)
      ensure_pre_insertion_validity!(node, ref)
      nodes = detach_dom_nodes(node)
      ref_bn = ref.respond_to?(:__dommy_backend_node__) ? ref.__dommy_backend_node__ : nil
      if ref_bn && ref_bn.parent == @__node__
        nodes.each { |n| ref_bn.add_previous_sibling(n) }
      else
        nodes.each { |n| @__node__.add_child(n) }
      end
      node
    end

    def replace_child(new_child, old_child)
      coerce_node_argument!(new_child)
      old_bn = old_child.respond_to?(:__dommy_backend_node__) ? old_child.__dommy_backend_node__ : nil
      raise DOMException::NotFoundError, "node is not a child of this fragment" unless old_bn && old_bn.parent == @__node__

      ensure_pre_insertion_validity!(new_child, old_child)
      detach_dom_nodes(new_child).each { |n| old_bn.add_previous_sibling(n) }
      old_bn.unlink
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

    private

    def element_children
      @__node__.element_children.each_with_object([]) do |node, out|
        wrapped = @document.wrap_node(node)
        out << wrapped if wrapped
      end
    end

    # Fragments aren't part of the bubble chain; nil terminates
    # bubbling at the boundary (shadow root, detached fragment, etc.).
    def __internal_event_parent__
      nil
    end
  end

  # CharacterData base — TextNode and CommentNode share the data /
  # nodeValue / textContent API and `remove` / `cloneNode` semantics.
  class CharacterDataNode
    include Node
    include EventTarget
    # `before` / `after` / `replaceWith` (+ their argument coercion) — the same
    # spec-correct implementation Element uses, minus appendChild/insertBefore.
    include Internal::ChildNode

    # The owning Dommy document (as Element exposes), so cross-document adoption
    # checks work for text/comment nodes too.
    attr_reader :document

    def __dommy_backend_node__ = @__node__

    # EventTarget needs a parent for event propagation; a character-data node
    # bubbles to its parent element.
    def __internal_event_parent__
      @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    # Text.splitText / CharacterData split: break the node at `offset`, keeping
    # [0, offset) here and returning a new sibling node with the remainder.
    def split_text(offset)
      off = offset.to_i
      full = @__node__.content
      raise DOMException::IndexSizeError, "offset #{off} is out of bounds" if off.negative? || off > full.length

      rest = full[off..] || ""
      write_data(full[0, off])
      new_node = @document.create_text_node(rest)
      if @__node__.parent
        new_bn = new_node.__dommy_backend_node__
        @__node__.add_next_sibling(new_bn)
        # The new node is inserted right after self — a childList addition record.
        @document.notify_child_list_mutation(target_node: @__node__.parent, added_nodes: [new_bn], removed_nodes: [])
      end
      new_node
    end

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
    end

    # Snake_case facade (CRuby idiomatic)

    def data
      @__node__.content
    end

    def data=(value)
      write_data(value)
    end

    def node_value
      @__node__.content
    end

    def node_value=(value)
      write_data(value)
    end

    def text_content
      @__node__.content
    end

    def text_content=(value)
      write_data(value)
    end

    def remove
      @document.remove_node_with_notify(@__node__)
      nil
    end

    def parent_node
      @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    # parentElement is the parent only when it is an element (a document or
    # fragment parent is a parentNode but not a parentElement).
    def parent_element
      @document.wrap_node(@__node__.parent) if @__node__.parent&.element?
    end

    def next_sibling
      @__node__.next && @document.wrap_node(@__node__.next)
    end

    def previous_sibling
      @__node__.previous && @document.wrap_node(@__node__.previous)
    end

    def [](key)
      __js_get__(key.to_s)
    end

    def []=(key, value)
      __js_set__(key.to_s, value)
    end

    # WHATWG nodeName for character-data nodes is a per-type constant
    # ("#text" / "#comment" / "#cdata-section"), not the element name.
    def node_name
      case node_type
      when 3 then "#text"
      when 4 then "#cdata-section"
      when 8 then "#comment"
      end
    end

    # CharacterData length / mutation methods. Offsets and counts are UTF-16 code
    # units per spec; for BMP text (the common case) Ruby char indices match.
    # Each mutating op routes through write_data, which fires the characterData
    # MutationObserver record.

    def length
      utf16_length(@__node__.content)
    end

    # CharacterData offsets and counts are measured in UTF-16 code units, not
    # Unicode code points, so an astral character (e.g. an emoji) counts as 2.
    def utf16_length(str)
      str.encode(Encoding::UTF_16LE).bytesize / 2
    end

    # Extract `count` UTF-16 code units from `str` starting at code unit
    # `offset`. Slicing on the UTF-16LE byte buffer keeps astral characters
    # intact for the offsets these APIs actually produce.
    #
    # If the range starts or ends inside a surrogate pair the result would be a
    # lone (unpaired) surrogate. JS strings can hold those; a Ruby UTF-8 String
    # cannot, so re-raise the raw encoding error as a clear, intentional message
    # rather than leaking "\xDF on UTF-16LE" to the caller. This is a Dommy
    # limitation and, since splitting a surrogate pair signals a UTF-16 offset
    # bug in the caller, failing loud is deliberate.
    def utf16_slice(str, offset, count)
      buf = str.encode(Encoding::UTF_16LE)
      buf.byteslice(offset * 2, count * 2).encode(Encoding::UTF_8, Encoding::UTF_16LE)
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise "cannot split a UTF-16 surrogate pair: the requested range would " \
            "produce a lone surrogate, which Dommy cannot represent"
    end

    def substring_data(offset, count)
      s = @__node__.content
      len = utf16_length(s)
      o = to_uint32(offset)
      raise DOMException::IndexSizeError, "offset out of bounds" if o > len

      c = [to_uint32(count), len - o].min
      utf16_slice(s, o, c)
    end

    # ECMAScript ToUint32 — WebIDL `unsigned long` conversion for a data offset
    # or count: ToNumber (a non-numeric string is NaN), truncate toward zero,
    # then take modulo 2**32 (so -1 wraps to 4294967295, 0x100000000+2 to 2).
    def to_uint32(value)
      num =
        case value
        when Integer then value
        when Numeric then value
        when nil then 0 # JS null -> 0
        else Float(value.to_s) rescue Float::NAN
        end
      return 0 unless num.respond_to?(:finite?) ? num.finite? : true

      num.to_i % (2**32)
    end

    def append_data(value)
      write_data(@__node__.content + dom_string(value))
    end

    # WebIDL DOMString coercion for a CharacterData mutation argument: JS null
    # becomes the string "null" (undefined already stringifies to "undefined").
    def dom_string(value)
      value.nil? ? "null" : value.to_s
    end

    def insert_data(offset, value)
      replace_data(offset, 0, value)
    end

    def delete_data(offset, count)
      replace_data(offset, count, "")
    end

    def replace_data(offset, count, value)
      s = @__node__.content
      len = utf16_length(s)
      o = to_uint32(offset)
      raise DOMException::IndexSizeError, "offset out of bounds" if o > len

      c = [to_uint32(count), len - o].min
      write_data(utf16_slice(s, 0, o) + dom_string(value) + utf16_slice(s, o + c, len - (o + c)))
    end

    def __js_get__(key)
      case key
      when "nodeType"
        node_type
      when "nodeName"
        node_name
      when "textContent"
        @__node__.content
      when "data"
        @__node__.content
      when "nodeValue"
        @__node__.content
      when "length"
        length
      when "parentNode"
        parent_node
      when "parentElement"
        parent_element
      when "ownerDocument"
        @document
      when "nextSibling"
        next_sibling
      when "previousSibling"
        previous_sibling
      when "childNodes"
        # CharacterData is a leaf node: childNodes is always an empty (but
        # present and iterable) NodeList, and firstChild/lastChild are null.
        # DOM-walking code (e.g. idiomorph's morphChildren) iterates
        # `node.childNodes` on every node, so a missing one crashes it.
        NodeList.new
      when "firstChild", "lastChild"
        nil
      when "assignedSlot"
        assigned_slot
      else
        Bridge::ABSENT # unknown property: JS undefined, `in` absent
      end
    end

    # Slottable mixin: the <slot> this text node is assigned to. A text node has
    # no `slot` attribute, so it targets the default (unnamed) slot of its parent
    # element's shadow tree; a closed shadow tree hides the assignment (null).
    def assigned_slot
      parent = @__node__.parent
      return nil unless parent.respond_to?(:element?) && parent.element?

      host = @document.wrap_node(parent)
      return nil unless host.respond_to?(:shadow_root)

      sr = host.shadow_root
      return nil unless sr
      return nil if sr.__js_get__("mode") == "closed"

      sr.query_selector_all("slot").find do |slot|
        (slot.respond_to?(:name) ? slot.name.to_s : "") == ""
      end
    end

    def __js_set__(key, value)
      case key
      when "textContent", "data", "nodeValue"
        write_data(value)
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[remove before after replaceWith isEqualNode hasChildNodes
      appendData insertData deleteData replaceData substringData contains
      isSameNode getRootNode normalize splitText compareDocumentPosition
      lookupNamespaceURI lookupPrefix isDefaultNamespace
      appendChild insertBefore removeChild replaceChild
      addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "hasChildNodes"
        false
      when "contains"
        # A leaf node contains only itself (no descendants).
        args[0].respond_to?(:__dommy_backend_node__) &&
          args[0].__dommy_backend_node__ == @__node__
      when "appendChild", "insertBefore", "replaceChild"
        # WebIDL coerces the Node argument first (null/non-Node → TypeError);
        # only then does the leaf reject the insertion. WHATWG pre-insert /
        # replace step 1 checks the PARENT type before the reference child, so a
        # leaf parent is a HierarchyRequestError even when `child` isn't a child.
        raise Bridge::TypeError, "Argument is not a Node." unless args[0].is_a?(Dommy::Node)

        raise DOMException::HierarchyRequestError, "this node type does not support children"
      when "removeChild"
        raise Bridge::TypeError, "Argument is not a Node." unless args[0].is_a?(Dommy::Node)

        raise DOMException::NotFoundError, "the node to be removed is not a child of this node"
      when "compareDocumentPosition"
        compare_document_position(args[0])
      when "isSameNode"
        is_same_node(args[0])
      when "getRootNode"
        get_root_node(args[0])
      when "lookupNamespaceURI"
        lookup_namespace_uri(args[0])
      when "lookupPrefix"
        lookup_prefix(args[0])
      when "isDefaultNamespace"
        is_default_namespace(args[0])
      when "normalize"
        nil # a leaf has no child text runs to merge
      when "splitText"
        split_text(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "appendData"
        raise Bridge::TypeError, "appendData requires 1 argument." if args.empty?

        append_data(args[0])
      when "insertData"
        insert_data(args[0], args[1])
      when "deleteData"
        delete_data(args[0], args[1])
      when "replaceData"
        replace_data(args[0], args[1], args[2])
      when "substringData"
        raise Bridge::TypeError, "substringData requires 2 arguments." if args.length < 2

        substring_data(args[0], args[1])
      when "remove"
        remove
        Bridge::UNDEFINED # ChildNode#remove is void -> JS undefined, not null
      when "before"
        before(*args)
      when "after"
        after(*args)
      when "replaceWith"
        replace_with(*args)
      when "isEqualNode"
        is_equal_node(args[0])
      end
    end

    # ChildNode mixin: WHATWG DOM defines `before`, `after`, `replaceWith` on
    # all child nodes, including Text and Comment. The spec-correct algorithm
    # (viable previous/next sibling, forward insertion, string coercion,
    # Fragment/cross-document adoption) lives in Internal::ParentNode and is
    # shared with Element — these just forward to it.

    def before(*args)
      child_node_before(args)
    end

    def after(*args)
      child_node_after(args)
    end

    def replace_with(*args)
      child_node_replace_with(args)
    end

    private

    def write_data(value)
      old = @__node__.content
      @__node__.content = value.to_s
      @document.notify_character_data_mutation(target_node: @__node__, old_value: old)
    end
  end

  class TextNode < CharacterDataNode
    def node_type
      3
    end

    # Own __js_call__ methods, on top of CharacterDataNode's.
    js_methods %w[cloneNode]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        @document.create_text_node(@__node__.text)
      else
        super
      end
    end
  end

  # CDATASection — a Text subtype (nodeType 4). CharacterData methods and the
  # "#cdata-section" nodeName come from CharacterDataNode via node_type.
  class CDATASectionNode < TextNode
    def node_type
      4
    end
  end

  class CommentNode < CharacterDataNode
    def node_type
      8
    end

    # Own __js_call__ methods, on top of CharacterDataNode's.
    js_methods %w[cloneNode]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        @document.create_comment(@__node__.content)
      else
        super
      end
    end
  end

  # ProcessingInstruction (`<?target data?>`, nodeType 7) — CharacterData with a
  # `target`. Backed by a real backend node (created via
  # document.createProcessingInstruction), so it participates in the tree like
  # Text/Comment: insertion, ChildNode methods, identity caching and
  # serialization all come from the shared CharacterDataNode machinery.
  class ProcessingInstructionNode < CharacterDataNode
    def node_type
      7
    end

    # WHATWG: a ProcessingInstruction's nodeName is its target.
    def node_name
      @__node__.target
    end

    def target
      @__node__.target
    end

    def __js_get__(key)
      case key
      when "target"
        @__node__.target
      else
        super
      end
    end

    # Own __js_call__ methods, on top of CharacterDataNode's.
    js_methods %w[cloneNode]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        @document.create_processing_instruction(@__node__.target, @__node__.content)
      else
        super
      end
    end
  end

  # (`LiveChildren` removed — `el.children` now returns a
  # `Dommy::HTMLCollection` initialized with a re-evaluating block.)

  class ClassList
    include Enumerable

    # `attribute` is the content attribute this token list reflects ("class" for
    # `classList`, "rel" for `relList`, "sandbox", "sizes", "for", …).
    def initialize(element, attribute = "class")
      @element = element
      @attribute = attribute
    end

    def length
      class_tokens.length
    end

    alias size length

    def item(index)
      i = index.to_i
      return nil if i.negative?

      class_tokens[i]
    end

    def value
      @element.__dommy_backend_node__[@attribute].to_s
    end

    def value=(new_value)
      @element.set_attribute(@attribute, new_value.to_s)
    end

    # Spec: contains() does NOT validate (no SyntaxError on empty).
    def contains?(token)
      class_tokens.include?(token.to_s)
    end

    # DOMTokenList membership. Defined explicitly (rather than inheriting
    # Enumerable#include?, which re-iterates via #each) so a class-selector match
    # is a single Array#include? over the cached tokens — the hot path under a
    # querySelector-heavy SPA.
    def include?(token)
      class_tokens.include?(token.to_s)
    end

    def add(*tokens)
      update_tokens { |existing| existing | normalize_tokens(tokens) }
      nil
    end

    def remove(*tokens)
      update_tokens { |existing| existing - normalize_tokens(tokens) }
      nil
    end

    def replace(old_token, new_token)
      # Spec order: both tokens' empty checks (SyntaxError) precede both
      # whitespace checks (InvalidCharacterError) — so replace(" ", "") is a
      # SyntaxError (the empty newToken), not an InvalidCharacterError.
      old_s = stringify_token(old_token)
      new_s = stringify_token(new_token)
      raise DOMException::SyntaxError, "token is empty" if old_s.empty? || new_s.empty?
      if old_s.match?(/[ \t\n\f\r]/) || new_s.match?(/[ \t\n\f\r]/)
        raise DOMException::InvalidCharacterError, "token contains whitespace"
      end

      tokens = class_tokens
      idx = tokens.index(old_s)
      return false unless idx

      # class_tokens returns the cached token array; dup before mutating so the
      # in-place assignment can't corrupt the cache (whose key is still the old
      # raw attribute string, which would then hand stale tokens to later reads).
      updated = tokens.dup
      updated[idx] = new_s
      @element.set_attribute(@attribute, updated.uniq.join(" "))
      true
    end

    def [](index)
      item(index)
    end

    def each(&blk)
      class_tokens.each(&blk)
    end

    def to_a
      class_tokens.dup
    end

    def to_s
      value
    end

    def __js_get__(key)
      case key
      when "length"
        length
      when "value"
        value
      else
        # Indexed getter: `classList[i]` is an undefined-returning indexed
        # property — out-of-range or negative indices yield JS `undefined`
        # (unlike `item(i)`, which returns null). Returning Ruby nil here would
        # marshal as JS null, so use the UNDEFINED sentinel.
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          i = key.to_i
          token = i.negative? ? nil : class_tokens[i]
          token.nil? ? Bridge::UNDEFINED : token
        else
          Bridge::ABSENT # unknown non-index property
        end
      end
    end

    def __js_set__(key, val)
      case key
      when "value"
        self.value = val
      end

      nil
    end

    include Bridge::Methods
    # NOTE: `supports` is intentionally absent — for the class attribute's token
    # list it must throw a TypeError, which `list.supports(...)` (not a function)
    # already does.
    js_methods %w[add remove contains toggle replace item toString]
    def __js_call__(method, args)
      case method
      when "add"
        update_tokens { |tokens| tokens | normalize_tokens(args) }
        Bridge::UNDEFINED
      when "remove"
        update_tokens { |tokens| tokens - normalize_tokens(args) }
        Bridge::UNDEFINED
      when "contains"
        # contains() does not validate; null coerces to the string "null".
        class_tokens.include?(stringify_token(args[0]))
      when "toggle"
        toggle(args[0], args[1])
      when "replace"
        replace(args[0], args[1])
      when "item"
        item(args[0])
      when "toString"
        value
      else
        nil
      end
    end

    private

    def toggle(token, force)
      name = validate_token(token)
      present = class_tokens.include?(name)
      force_given = !(force.nil? || force.equal?(Bridge::UNDEFINED))

      # Spec: toggle runs the update steps only when it actually adds or removes.
      # With an explicit force that already matches the current state it's a
      # no-op — the attribute is left byte-for-byte untouched (no re-serialize).
      if force_given
        want = !!force
        return want if want == present

        update_tokens { |tokens| want ? tokens | [name] : tokens - [name] }
        return want
      end

      desired = !present
      update_tokens { |tokens| desired ? tokens | [name] : tokens - [name] }
      desired
    end

    # USVString coercion of a token argument: JS `null` becomes the string
    # "null" (so `add(null)` adds the token "null"), not the empty string.
    def stringify_token(token)
      token.nil? ? "null" : token.to_s
    end

    # Spec: any empty-string argument throws SyntaxError; any token
    # containing ASCII whitespace throws InvalidCharacterError. Applies
    # to add / remove / replace / toggle.
    def normalize_tokens(args)
      args.map { |t| validate_token(t) }
    end

    def validate_token(token)
      s = stringify_token(token)
      raise DOMException::SyntaxError, "token is empty" if s.empty?
      raise DOMException::InvalidCharacterError, "token contains whitespace: #{s.inspect}" if s.match?(/\s/)

      s
    end

    # The DOMTokenList token set: the class attribute parsed as an *ordered set*
    # (whitespace-split, duplicates removed preserving first-seen order). length,
    # item, iteration, and contains all operate on this set; `value`/`toString`
    # return the raw attribute. ASCII whitespace per the spec is space/tab/LF/FF/CR.
    def class_tokens
      raw = @element.__dommy_backend_node__[@attribute].to_s
      # Cache the parsed token list keyed by the raw attribute string: a class
      # selector match re-reads this for every element on every querySelector,
      # and the split/reject/uniq dominated heavy-SPA load profiles. The key is
      # the raw value itself, so any change (add/remove/className=, or a direct
      # backend mutation) yields a different key and transparently recomputes.
      cached = @token_cache
      return cached[1] if cached && cached[0] == raw

      tokens = raw.split(/[ \t\n\f\r]+/).reject(&:empty?).uniq
      @token_cache = [raw, tokens]
      tokens
    end

    # DOMTokenList "update steps": serialize the (deduplicated) token set back to
    # the class attribute. add/remove/replace always run this, so duplicates
    # collapse and whitespace normalizes even on a no-op token. The one carve-out
    # (per spec) is an empty set with no existing attribute — don't create one.
    def update_tokens
      tokens = yield(class_tokens)
      return if tokens.empty? && !@element.__dommy_backend_node__.key?(@attribute)

      @element.set_attribute(@attribute, tokens.join(" "))
    end
  end

  # `Element#dataset` proxy. `el.dataset.fooBar` reads / writes
  # `data-foo-bar` per the HTMLOrForeignElement.dataset spec
  # (camelCase ↔ kebab-case round-trip).
  class DatasetMap
    def initialize(element)
      @element = element
    end

    def __js_get__(key)
      # A missing data-* attribute reads as JS `undefined` (and `"foo" in dataset`
      # is false), per DOMStringMap semantics.
      value = @element.__dommy_backend_node__[attr_name(key)]
      value.nil? ? Bridge::ABSENT : value
    end

    def __js_set__(key, value)
      @element.set_attribute(attr_name(key), value.to_s)
      nil
    end

    # Named deleter (`delete el.dataset.foo`): removes the data-* attribute.
    def __js_delete__(key)
      @element.remove_attribute(attr_name(key))
      true
    end

    def __js_call__(_method, _args)
      nil
    end

    # WebIDL "supported property names" for DOMStringMap: each `data-*`
    # attribute's name with the `data-` prefix stripped and `-x` sequences
    # camel-cased (`data-date-of-birth` → `dateOfBirth`, `data-` → ``).
    def __js_named_props__
      Backend.attribute_nodes(@element.__dommy_backend_node__).filter_map do |a|
        name = Backend.attribute_ns_info(a)[:qualified_name]
        next unless name.start_with?("data-")

        name.sub(/\Adata-/, "").gsub(/-([a-z])/) { ::Regexp.last_match(1).upcase }
      end
    end

    private

    def attr_name(key)
      "data-#{key.to_s.gsub(/[A-Z]/) { |m| "-#{m.downcase}" }}"
    end
  end

  # Stub `DOMRect` for `getBoundingClientRect` — no layout engine,
  # so all values are 0. Consumer code that uses these for *relative*
  # positioning sees zeroed values; absolute layout assertions need
  # the real browser.
  class DOMRect
    attr_reader :x, :y, :width, :height

    def initialize(x: 0, y: 0, width: 0, height: 0)
      @x = x
      @y = y
      @width = width
      @height = height
    end

    def top
      @y
    end

    def left
      @x
    end

    def right
      @x + @width
    end

    def bottom
      @y + @height
    end

    def __js_get__(key)
      case key
      when "x", "left"
        @x
      when "y", "top"
        @y
      when "width"
        @width
      when "height"
        @height
      when "right"
        @x + @width
      when "bottom"
        @y + @height
      else
        Bridge::ABSENT
      end
    end

    def js_null?
      false
    end
  end

  class StyleDeclaration
    include Enumerable

    def initialize(element)
      @element = element
    end

    # CSSStyleDeclaration interface: cssText serializes the parsed declaration
    # block (`prop: value;` joined by spaces), dropping invalid declarations.
    # The setter reparses and rewrites the `style` attribute in that form.
    def css_text
      serialize_properties(properties)
    end

    def css_text=(value)
      write_properties(parse_declarations(value))
    end

    def length
      properties.size
    end

    # `style[0]` returns the property name at that index (matches
    # `style.item(i)` in real DOM). String key form (`style["color"]`)
    # is a convenience shortcut for `getPropertyValue`.
    def [](key)
      if key.is_a?(Integer)
        properties.keys[key]
      else
        properties[key.to_s]
      end
    end

    def []=(name, value)
      set_property(name, value)
    end

    def each(&blk)
      properties.keys.each(&blk)
    end

    # camelCase JS property accessors → kebab-case CSS property name.
    # `style.backgroundColor = "red"` becomes `background-color: red`.
    def method_missing(name, *args)
      key = method_to_css_name(name)
      if name.to_s.end_with?("=")
        set_property(key, args.first)
      elsif properties.key?(key)
        properties[key]
      else
        ""
      end
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    def __js_get__(key)
      case key
      when "cssText"
        css_text
      when "length"
        length
      else
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          self[key.to_i]
        else
          # An unset CSS property reads as "" (per CSSStyleDeclaration), not nil —
          # `el.style.display` is "" until assigned, which `v-show` and other
          # display-toggling code compares against.
          properties[method_to_css_name(key)] || ""
        end
      end
    end

    def __js_set__(key, value)
      case key
      when "cssText"
        self.css_text = value
      else
        set_property(method_to_css_name(key), value)
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[setProperty removeProperty getPropertyValue item]
    def __js_call__(method, args)
      case method
      when "setProperty"
        set_property(args[0], args[1])
      when "removeProperty"
        remove_property(args[0])
      when "getPropertyValue"
        properties[args[0].to_s]
      when "item"
        properties.keys[args[0].to_i]
      else
        nil
      end
    end

    private

    def method_to_css_name(name)
      s = name.to_s.sub(/=\z/, "")
      # snake_case (Ruby idiomatic) → kebab; camelCase (JS idiomatic) → kebab.
      s.include?("_") ? s.tr("_", "-") : s.gsub(/[A-Z]/) { |m| "-#{m.downcase}" }
    end

    def set_property(name, value)
      key = name.to_s
      props = properties
      if value.nil? || value.to_s.empty?
        props.delete(key)
      else
        props[key] = value.to_s
      end

      write_properties(props)
      nil
    end

    def remove_property(name)
      key = name.to_s
      props = properties
      removed = props.delete(key)
      write_properties(props)
      removed
    end

    def properties
      parse_declarations(@element.__dommy_backend_node__["style"].to_s)
    end

    # Parse a declaration block into an ordered { property => value } hash,
    # dropping declarations whose value is invalid (empty, or — like the second
    # colon in "color:: invalid" — containing a bare colon outside parentheses).
    def parse_declarations(str)
      str.to_s.split(";").each_with_object({}) do |entry, out|
        key, value = entry.split(":", 2)
        next unless key && value

        name = key.strip
        val = value.strip
        next if name.empty? || !valid_declaration_value?(val)

        out[name] = val
      end
    end

    def valid_declaration_value?(value)
      return false if value.empty?

      depth = 0
      value.each_char do |c|
        case c
        when "(" then depth += 1
        when ")" then depth -= 1 if depth.positive?
        when ":" then return false if depth.zero?
        end
      end
      true
    end

    def serialize_properties(props)
      props.map { |k, v| "#{k}: #{v};" }.join(" ")
    end

    def write_properties(props)
      if props.empty?
        @element.remove_attribute("style") if @element.__dommy_backend_node__.key?("style")
      else
        @element.set_attribute("style", serialize_properties(props))
      end
    end
  end

  class Element
    include EventTarget
    include Node
    include Internal::ParentNode

    attr_reader :document

    def __dommy_backend_node__ = @__node__

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
      @class_list = ClassList.new(self)
      @style = StyleDeclaration.new(self)
      @dataset = DatasetMap.new(self)
      # `HTMLCollection` re-evaluates the child list on every
      # property access so callers that capture `el[:children]` once
      # see DOM mutations made between iterations — required by list
      # reconciliation patterns that rely on the spec's live
      # HTMLCollection semantics to detect already-positioned nodes.
      @live_children = HTMLCollection.new do
        @__node__.element_children.map { |n| @document.wrap_node(n) }.compact
      end
      # Live `childNodes` (all node types, not just elements), cached so
      # `el.childNodes === el.childNodes` holds like the spec's live NodeList.
      @live_child_nodes = LiveNodeList.new do
        @__node__.children.map { |n| @document.wrap_node(n) }.compact
      end
    end

    # ----- Public Ruby API (snake_case) -----
    #
    # Mirrors HTMLElement DOM properties / methods in idiomatic Ruby
    # form. The bridge protocol (`__js_get__` / `__js_call__`) routes
    # camelCase JS names through these same accessors, so any fix here
    # is visible in both views.

    def text_content
      @__node__.text
    end

    def text_content=(value)
      # textContent is a nullable DOMString, so null AND undefined both mean "no
      # value" -> clear the children with no replacement text. Otherwise replace
      # all children with a single Text node. Unlink the old children (rather
      # than the backend's `content=`, which frees their whole subtree) so a
      # reference to a removed node keeps its own descendants intact.
      removed = @__node__.children.to_a
      str = nullable_dom_string(value)
      removed.each(&:unlink)
      unless str.empty?
        @__node__.add_child(@document.create_text_node(str).__dommy_backend_node__)
      end
      added = @__node__.children.to_a
      notify_child_list(added: added, removed: removed)
    end

    def inner_html
      if @__node__.name == "template"
        @document.template_content_inner_html(self)
      else
        @__node__.inner_html
      end
    end

    def inner_html=(value)
      removed = @__node__.children.to_a
      if @__node__.name == "template"
        # `<template>` content is invisible to outer selectors in real DOM (it
        # lives in a separate DocumentFragment exposed via `[:content]`).
        @document.attach_template_content(self, value.to_s)
      else
        @__node__.inner_html = value.to_s
        @document.migrate_template_descendants(@__node__)
        mark_fragment_scripts_started(@__node__.children.to_a)
      end
      notify_child_list(added: @__node__.children.to_a, removed: removed)
    end

    # Per the HTML fragment parsing algorithm, a <script> created while parsing a
    # fragment (innerHTML / insertAdjacentHTML / outerHTML) has its "already
    # started" flag set, so it never executes when inserted. Flag every script in
    # the freshly parsed backend subtree before the connection notification —
    # which is what would otherwise run them — fires.
    def mark_fragment_scripts_started(backend_nodes)
      backend_nodes.each do |nk|
        next unless nk.respond_to?(:element?) && nk.element?

        if nk.name == "script"
          wrapped = @document.wrap_node(nk)
          wrapped&.__internal_mark_script_already_started__ if wrapped.respond_to?(:__internal_mark_script_already_started__)
        end
        mark_fragment_scripts_started(nk.children.to_a) if nk.respond_to?(:children)
      end
    end

    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"

    # Record the namespace/prefix/localName an element was created with via
    # createElementNS, so the getters report them faithfully (Nokogiri can't
    # always round-trip a foreign-namespace prefix).
    def __internal_set_namespace__(namespace, prefix, local_name, qualified_name)
      @__ns_uri = namespace
      @__ns_prefix = prefix
      @__ns_local = local_name
      @__ns_qname = qualified_name
      nil
    end

    # tagName is the qualified name, ASCII-upper-cased only for an HTML-namespace
    # element whose node document is an HTML document. An XHTML element (HTML
    # namespace, but in an XML document) and any non-HTML-namespace element keep
    # their case.
    def tag_name
      qname = @__ns_qname || @__node__.name
      html_ns = @__ns_qname ? @__ns_uri == HTML_NAMESPACE : true
      html_ns && @document.html_document? ? qname.upcase(:ascii) : qname
    end

    def element_prefix
      @__ns_prefix
    end

    # The [namespace, prefix, local_name] explicitly assigned via createElementNS,
    # or nil when the element wasn't created with an explicit namespace. Lets the
    # XML serializer recover element-namespace info the makiri backend (lexbor,
    # HTML-only) doesn't retain.
    def __internal_created_namespace__
      return nil unless @__ns_qname

      [@__ns_uri, @__ns_prefix, @__ns_local]
    end

    def id
      @__node__["id"].to_s
    end

    def id=(value)
      set_attribute("id", value.to_s)
    end

    def class_name
      @__node__["class"].to_s
    end

    def class_name=(value)
      set_attribute("class", value.to_s)
    end

    def class_list
      @class_list
    end

    # Element + namespace combinations for which a reflected DOMTokenList IDL
    # attribute is defined; elsewhere the attribute does not exist (→ undefined).
    REFLECTED_TOKEN_LIST_HOSTS = {
      "relList" => {html: %w[a area link], svg: %w[a]},
      "htmlFor" => {html: %w[output]},
      "sandbox" => {html: %w[iframe]},
      "sizes" => {html: %w[link]}
    }.freeze

    SVG_NAMESPACE = "http://www.w3.org/2000/svg"

    # A reflected DOMTokenList for `prop` backed by content attribute
    # `attribute`, cached for identity (`el.relList === el.relList`). Returns the
    # UNDEFINED sentinel (→ JS `undefined`) when the attribute is not defined on
    # this element in its namespace.
    def reflected_token_list(prop, attribute)
      hosts = REFLECTED_TOKEN_LIST_HOSTS[prop]
      ns = namespace_uri
      ln = local_name
      applicable =
        (ns == HTML_NAMESPACE && hosts[:html].include?(ln)) ||
        (ns == SVG_NAMESPACE && Array(hosts[:svg]).include?(ln))
      return Bridge::UNDEFINED unless applicable

      (@reflected_token_lists ||= {})[prop] ||= ClassList.new(self, attribute)
    end

    def style
      @style
    end

    def dataset
      @dataset
    end

    def children
      @live_children
    end

    def parent_element
      @document.wrap_node(@__node__.parent) if @__node__.parent&.element?
    end

    alias parent parent_element

    def parent_node
      @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    def first_element_child
      @document.wrap_node(@__node__.element_children.first)
    end

    def last_element_child
      @document.wrap_node(@__node__.element_children.last)
    end

    def first_child
      @document.wrap_node(@__node__.children.first)
    end

    def last_child
      @document.wrap_node(@__node__.children.last)
    end

    def child_element_count
      @__node__.element_children.size
    end

    def child_nodes
      NodeList.new(@__node__.children.map { |n| @document.wrap_node(n) }.compact)
    end

    # Live NodeList over this element's children. Reflects later
    # mutations on every access.
    def live_child_nodes
      @live_child_nodes ||= LiveNodeList.new do
        @__node__.children.map { |n| @document.wrap_node(n) }.compact
      end
    end

    def has_child_nodes?
      @__node__.children.any?
    end

    def has_attributes?
      Backend.attribute_nodes(@__node__).any?
    end

    def next_sibling
      @__node__.next && @document.wrap_node(@__node__.next)
    end

    def previous_sibling
      @__node__.previous && @document.wrap_node(@__node__.previous)
    end

    def next_element_sibling
      node = @__node__.next
      node = node.next while node && !node.element?
      node && @document.wrap_node(node)
    end

    def previous_element_sibling
      node = @__node__.previous
      node = node.previous while node && !node.element?
      node && @document.wrap_node(node)
    end

    # Outer HTML — serializes this element and its subtree. Setter
    # replaces this element in its parent with the parsed fragment.
    def outer_html
      @__node__.to_html
    end

    # Per WHATWG DOM Parsing:
    #   - parent is null (detached element) → return silently
    #   - parent is the Document (`<html>` element) → throw
    #     NoModificationAllowedError (can't replace the document
    #     element via this API)
    #   - otherwise, parse `html` as a fragment in the parent's
    #     context and replace this element with the parsed nodes
    def outer_html=(html)
      parent = @__node__.parent
      return unless parent

      if parent.is_a?(Backend.document_class)
        raise(
          DOMException::NoModificationAllowedError,
          "outerHTML setter not allowed on the document element"
        )
      end

      fragment = Parser.fragment(html.to_s, owner_doc: @__node__.document)
      anchor = @__node__.next_sibling
      removed = @__node__
      new_nodes = fragment.children.to_a
      mark_fragment_scripts_started(new_nodes)
      @__node__.unlink
      if anchor
        new_nodes.reverse_each { |n| anchor.add_previous_sibling(n) }
      else
        new_nodes.each { |n| parent.add_child(n) }
      end

      notify_child_list(added: new_nodes, removed: [removed], target: parent)
    end

    # `el.contains(other)` — true if `other` is `el` itself or any
    # descendant. Per spec, returns false for null/non-Node.
    def contains?(other)
      return false unless other.respond_to?(:__dommy_backend_node__)

      other_node = other.__dommy_backend_node__
      return true if other_node == @__node__

      Internal::NodeTraversal.ancestor_of?(@__node__, other_node)
    end

    # `el.getRootNode()` — returns the topmost ancestor (document,
    # ShadowRoot, fragment, or self if detached). If the element lives
    # inside a shadow tree, returns that ShadowRoot. Otherwise walks
    # until we hit the Nokogiri Document (then returns the Document).
    def root_node(options = nil)
      composed = options.is_a?(Hash) && EventTarget.js_truthy?(options.key?("composed") ? options["composed"] : options[:composed])
      sr = @document.__internal_shadow_root_containing__(@__node__)
      if sr
        # Default: the shadow root is the root. `composed: true` is
        # shadow-including — cross the boundary and continue from the host, so
        # the topmost document is returned.
        return sr unless composed
        return sr.host.root_node({"composed" => true}) if sr.host.respond_to?(:root_node)

        return sr
      end

      current = @__node__
      attached = false
      loop do
        parent = current.respond_to?(:parent) ? current.parent : nil
        break unless parent
        if parent.is_a?(Backend.document_class)
          attached = true
          break
        end

        current = parent
      end

      return @document if attached

      @document.wrap_node(current) || @document
    end

    alias get_root_node root_node

    # Merge adjacent text node siblings and drop empty text nodes.
    # WHATWG Node.normalize: drop empty Text nodes and merge each run of
    # contiguous Text nodes into the first, firing the matching mutation records
    # (childList for every removed node, characterData for the merged data).
    def toggle_attribute(name, force = nil)
      raise DOMException::InvalidCharacterError, "empty attribute name" if name.to_s.empty?

      key = name.to_s.downcase
      present = @__node__.key?(key)
      desired = force.nil? ? !present : !!force
      if desired
        set_attribute(key, "") unless present
        true
      else
        remove_attribute(key) if present
        false
      end
    end

    def matches?(selector)
      return false if selector.nil?
      ast = Internal::SelectorParser.parse!(selector)
      Internal::SelectorMatcher.matches?(self, ast, scope: self)
    end

    def get_elements_by_class_name(name)
      tokens = name.to_s.split(/\s+/).reject(&:empty?)
      root = @__node__
      doc = @document
      HTMLCollection.new do
        next [] if tokens.empty?

        selector = tokens.map { |t| ".#{t}" }.join("")
        root.css(selector).map { |n| doc.wrap_node(n) }.compact
      end
    end

    def get_elements_by_tag_name(name)
      HTMLCollection.elements_by_tag_name(@__node__, @document, name)
    end

    def get_elements_by_tag_name_ns(namespace, local_name)
      HTMLCollection.elements_by_tag_name_ns(@__node__, @document, namespace, local_name)
    end

    # NamedNodeMap of attributes. Lazily allocated and re-used so
    # `el.attributes === el.attributes` and `attr.ownerElement === el`.
    def attributes
      @attributes ||= NamedNodeMap.new(self)
    end

    # Public bridges to the attribute-name case machinery, for NamedNodeMap.
    def __internal_normalize_attr_key__(name) = normalize_attr_key(name)
    def __internal_case_sensitive_attribute_names__? = case_sensitive_attribute_names?

    def get_attribute_node(name)
      attributes.get_named_item(name)
    end

    def set_attribute_node(attr)
      attributes.set_named_item(attr)
    end

    def remove_attribute_node(attr)
      return nil unless attr.respond_to?(:name)

      attributes.remove_named_item(attr.name)
    end

    # HTML namespace constants — most HTML elements live in xhtml ns.
    def namespace_uri
      return @__ns_uri if @__ns_qname

      ns = Backend.namespace_of(@__node__)
      ns ? ns.href : HTML_NAMESPACE
    end

    def local_name
      return @__ns_local if @__ns_qname

      @__node__.name.downcase
    end

    # `slot` and `role` are simple reflected string attributes —
    # added as named accessors for happy-dom test parity.
    def slot
      @__node__["slot"].to_s
    end

    def slot=(value)
      set_attribute("slot", value.to_s)
    end

    # `assignedSlot` — for a slottable (a direct light-DOM child of a shadow
    # host), the `<slot>` in the host's *open* shadow tree it composes into,
    # else null. Per the spec's "open flag", a closed shadow tree always
    # returns null (mirrors `Element#shadowRoot` being null when closed).
    def assigned_slot
      parent = @__node__.parent
      return nil unless parent.respond_to?(:element?) && parent.element?

      host = @document.wrap_node(parent)
      return nil unless host.respond_to?(:shadow_root)

      sr = host.shadow_root
      return nil unless sr

      slot_name = @__node__.element? ? @__node__["slot"].to_s : ""
      sr.query_selector_all("slot").find do |slot|
        (slot.respond_to?(:name) ? slot.name.to_s : "") == slot_name
      end
    end

    def role
      @__node__["role"].to_s
    end

    def role=(value)
      set_attribute("role", value.to_s)
    end

    # The WAI-ARIA computed role (what `getByRole` / WPT's get_computed_role
    # report): an explicit valid `role` attribute, else the implicit HTML role.
    def computed_role
      Internal::AriaRole.compute(self)
    end

    # The WAI-ARIA accessible name (WPT's get_computed_label): aria-labelledby /
    # aria-label / native label / name-from-content / title.
    def computed_label
      Internal::AccessibleName.compute(self)
    end

    # The WAI-ARIA accessible description: aria-describedby / aria-description /
    # title (title only when not already used as the accessible name).
    def computed_description
      Internal::AccessibleDescription.compute(self)
    end

    # The accessibility tree rooted at this element (a synthetic root whose
    # children are this element's accessible nodes). See
    # Internal::AccessibilityTree.
    def accessibility_tree
      Internal::AccessibilityTree.build(self)
    end
    alias_method :aria_tree, :accessibility_tree

    # A Playwright-compatible ARIA snapshot (indented YAML outline) of this
    # element's accessibility subtree.
    def aria_snapshot
      Internal::AriaSnapshot.serialize(accessibility_tree)
    end

    # `Node.baseURI` — resolves against the document's base URL, which
    # in turn honors the first `<base href>` element (see
    # `Document#base_uri`).
    def base_uri
      @document.base_uri
    end

    def owner_document
      @document
    end

    # Walks parents up to the Document (or false when the chain
    # dead-ends). Crosses ShadowRoot boundaries: a node inside an
    # open or closed shadow tree is connected iff its host is.
    def is_connected?
      current = @__node__
      seen = {}
      loop do
        # Guard against unexpected cycles in malformed trees.
        return false if seen[Backend.identity_key(current)]

        seen[Backend.identity_key(current)] = true

        parent = current.respond_to?(:parent) ? current.parent : nil
        return false unless parent
        return true if parent.is_a?(Backend.document_class)

        sr = @document.__internal_shadow_root_for_fragment__(parent)
        if sr
          host = sr.host
          return false unless host

          current = host.__dommy_backend_node__
        else
          current = parent
        end
      end
    end

    alias connected? is_connected?

    # `focus()` — the HTML focusing steps, minus layout: Dommy treats any
    # element as focusable (except a disabled form control), then updates
    # document.activeElement AND fires the focus-change events a real
    # browser would — blur/focusout on the previously focused element, then
    # focus/focusin here, with relatedTarget linking the two. JS calling
    # `input.focus()` therefore triggers the same focus handlers a user's
    # click/tab would; already-focused and disabled targets are no-ops.
    def focus
      return nil if disabled_form_control?
      return nil if @document.__internal_focused_element__.equal?(self)

      previous = @document.__internal_focused_element__
      fire_focus_out(previous, self) if previous
      @document.__internal_set_active_element__(self)
      dispatch_event(Dommy::FocusEvent.new("focus", "composed" => true, "relatedTarget" => previous))
      dispatch_event(Dommy::FocusEvent.new("focusin",
        "bubbles" => true, "composed" => true, "relatedTarget" => previous))
      nil
    end

    def blur
      return nil unless @document.__internal_focused_element__.equal?(self)

      @document.__internal_set_active_element__(nil)
      fire_focus_out(self, nil)
      nil
    end

    # Elements that may host a Shadow DOM tree per the HTML spec.
    # Custom-element-style names (containing "-") are also allowed.
    SHADOW_HOST_TAGS = %w[
      article
      aside
      blockquote
      body
      div
      footer
      h1
      h2
      h3
      h4
      h5
      h6
      header
      main
      nav
      p
      section
      span
    ]
      .freeze

    # `el.attachShadow({ mode: "open" | "closed" })` — creates and
    # attaches a ShadowRoot. The shadow tree lives in its own
    # Nokogiri fragment and is invisible to the outer querySelector /
    # children chain. Per spec:
    #   - the `mode` field is REQUIRED in the init dict
    #   - only certain host element types are valid (see SHADOW_HOST_TAGS)
    #   - re-attaching to an element that already has a shadow throws
    def attach_shadow(options = nil)
      tag = @__node__.name.downcase
      unless SHADOW_HOST_TAGS.include?(tag) || tag.include?("-")
        raise DOMException::NotSupportedError, "<#{tag}> cannot host a shadow root"
      end

      raise DOMException::NotSupportedError, "Shadow root already attached" if @__shadow_root

      opts = options.is_a?(Hash) ? options : {}
      mode_raw = opts.key?("mode") ? opts["mode"] : opts[:mode]
      # `mode` is a required WebIDL dictionary member — omitting it, like an
      # invalid enum value below, is a (JS) TypeError, not a DOMException.
      raise Bridge::TypeError, "attachShadow init dictionary requires 'mode'" if mode_raw.nil?

      # `mode` is a WebIDL enum (ShadowRootMode); a value that isn't "open"/
      # "closed" fails enum conversion → TypeError, not a DOMException.
      mode = mode_raw.to_s
      raise Bridge::TypeError, "mode must be 'open' or 'closed'" unless %w[open closed].include?(mode)

      @__shadow_root = ShadowRoot.new(
        self,
        mode: mode,
        delegates_focus: opts["delegatesFocus"] || opts[:delegatesFocus] || false,
        slot_assignment: opts["slotAssignment"] || opts[:slotAssignment] || "named"
      )
      @__shadow_root
    end

    # `el.shadowRoot` — returns the attached ShadowRoot only when
    # mode is "open"; closed shadows are hidden from external code.
    def shadow_root
      return nil unless @__shadow_root
      return nil if @__shadow_root.mode == "closed"

      @__shadow_root
    end

    # Internal — gives access to the shadow root regardless of mode.
    # Used by event composition / `composedPath()`.
    def __internal_shadow_root__
      @__shadow_root
    end

    # `el.insertAdjacentElement(position, element)` — DOM spec positions:
    # "beforebegin", "afterbegin", "beforeend", "afterend". Returns the
    # inserted element or nil if position has no anchor (root cases).
    ADJACENT_POSITIONS = %w[beforebegin afterbegin beforeend afterend].freeze

    def insert_adjacent_element(position, element)
      # Position is an ASCII case-insensitive enum; anything else is a SyntaxError
      # (checked before the node coercion / anchor lookup, per spec).
      pos = position.to_s.downcase
      unless ADJACENT_POSITIONS.include?(pos)
        raise DOMException::SyntaxError, "'#{position}' is not a valid insertAdjacent position."
      end
      return nil unless element.respond_to?(:__dommy_backend_node__)

      case pos
      when "beforebegin"
        parent = @__node__.parent
        return nil unless parent

        validate_adjacent_document_insert!(parent, element)
        node = detach_for_insert(element)
        @__node__.add_previous_sibling(node)
        notify_child_list(added: [node], target: parent)
      when "afterbegin"
        node = detach_for_insert(element)
        first = @__node__.children.first
        first ? first.add_previous_sibling(node) : @__node__.add_child(node)
        notify_child_list(added: [node])
      when "beforeend"
        node = detach_for_insert(element)
        @__node__.add_child(node)
        notify_child_list(added: [node])
      when "afterend"
        parent = @__node__.parent
        return nil unless parent

        validate_adjacent_document_insert!(parent, element)
        node = detach_for_insert(element)
        @__node__.add_next_sibling(node)
        notify_child_list(added: [node], target: parent)
      end

      element
    end

    # beforebegin / afterend insert a sibling — when this element's parent is the
    # document, that would add a second document child, so run the document's
    # WHATWG pre-insertion hierarchy check (a second root element is rejected).
    def validate_adjacent_document_insert!(parent, element)
      return unless parent == @document.backend_doc

      @document.ensure_document_insertion_validity!([element], @__node__)
    end

    def insert_adjacent_html(position, html)
      # Position is ASCII case-insensitive ("beforeBegin" == "beforebegin").
      pos = position.to_s.downcase
      unless %w[beforebegin afterbegin beforeend afterend].include?(pos)
        raise DOMException::SyntaxError, "The value provided ('#{position}') is not one of 'beforeBegin', 'afterBegin', 'beforeEnd', or 'afterEnd'."
      end

      fragment = Parser.fragment(html.to_s, owner_doc: @__node__.document)
      nodes = fragment.children.to_a
      mark_fragment_scripts_started(nodes)
      # `add_previous_sibling` inserts immediately before the anchor, so a forward
      # walk preserves document order; `add_next_sibling` inserts immediately
      # after, so afterend walks in reverse to keep order.
      case pos
      when "beforebegin"
        parent = insertion_parent!
        nodes.each { |n| @__node__.add_previous_sibling(n) }
        notify_child_list(added: nodes, target: parent)
      when "afterbegin"
        first = @__node__.children.first
        if first
          nodes.each { |n| first.add_previous_sibling(n) }
        else
          nodes.each { |n| @__node__.add_child(n) }
        end

        notify_child_list(added: nodes)
      when "beforeend"
        nodes.each { |n| @__node__.add_child(n) }
        notify_child_list(added: nodes)
      when "afterend"
        parent = insertion_parent!
        nodes.reverse_each { |n| @__node__.add_next_sibling(n) }
        notify_child_list(added: nodes, target: parent)
      end

      nil
    end

    # The parent that a beforebegin/afterend insertion targets. Per the spec, if
    # the element has no parent, or its parent is the Document, there is nowhere
    # to insert a sibling — throw NoModificationAllowedError.
    def insertion_parent!
      parent = @__node__.parent
      is_document = parent && ((parent.respond_to?(:document?) && parent.document?) || parent.name == "document")
      if parent.nil? || is_document
        raise DOMException::NoModificationAllowedError, "The element has no parent."
      end

      parent
    end

    def insert_adjacent_text(position, text)
      return nil if text.to_s.empty?

      insert_adjacent_element(position, @document.create_text_node(text.to_s))
    end

    # Convenience alias matching the DOM idiom `String(el)` → outerHTML.
    def to_s
      outer_html
    end

    # Node type / NodeFilter bitmask constants — DOM Level 3 says these
    # are exposed on both the constructor and every instance. Defined
    # at the bottom of the class so subclasses inherit them too.
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

    # Standard DOM compareDocumentPosition. Returns 0 for self, a
    # CONTAINS/CONTAINED_BY bitmask for ancestor/descendant pairs, or
    # PRECEDING/FOLLOWING for siblings (and DISCONNECTED for unrelated
    # nodes).
    # compareDocumentPosition is provided generically by the Node module.

    # `Node.isSameNode(other)` — strict reference identity. The DOM
    # spec deprecates this in favor of `===`, but linkedom-style
    # tests still call it.
    def same_node?(other)
      equal?(other)
    end

    # Structural equality — same nodeType, same tagName, same attribute
    # set, and recursively-equal children. Used by linkedom test
    # suite and standard DOM Node.isEqualNode.
    def equal_node?(other)
      return false unless other.is_a?(Element)
      return false unless @__node__.name == other.__dommy_backend_node__.name
      return false unless attribute_signature == other.send(:attribute_signature)
      return false unless @__node__.children.size == other.__dommy_backend_node__.children.size

      @__node__.children.zip(other.__dommy_backend_node__.children).all? do |a, b|
        wa = @document.wrap_node(a)
        wb = @document.wrap_node(b)
        wa.respond_to?(:equal_node?) ? wa.equal_node?(wb) : a.content == b.content
      end
    end

    def remove
      @document.remove_node_with_notify(@__node__)
      nil
    end

    # ChildNode mixin — before / after / replaceWith with mixed args.

    def before(*args)
      child_node_before(args)
    end

    def after(*args)
      child_node_after(args)
    end

    def replace_with_nodes(*args)
      child_node_replace_with(args)
    end

    # `getInnerHTML()` — happy-dom alias for the `innerHTML` getter.
    # Real browsers add a `{ includeShadowRoots }` option which we
    # ignore (no Shadow DOM in Dommy).
    def get_inner_html(_options = nil)
      inner_html
    end

    def get_html(_options = nil)
      inner_html
    end

    # `click()` runs the HTML activation behavior around the dispatched event:
    # pre-click activation may change state (e.g. toggle a checkbox), the click
    # is dispatched, and then either the activation behavior runs (not canceled)
    # or the pre-click state is restored (default prevented). Elements with no
    # activation behavior (the default) just dispatch the event.
    def click
      pre = pre_click_activation_state
      event = MouseEvent.new("click", "bubbles" => true, "cancelable" => true, "button" => 0)
      not_canceled = dispatch_event(event)
      if not_canceled
        run_post_click_activation(pre) unless pre.nil?
        __run_click_activation_behavior__(event)
      elsif pre
        restore_pre_click_activation(pre)
      end
      not_canceled
    end

    # Pre-click activation hooks (checkbox/radio toggle-then-maybe-revert). The
    # default element has none; HTMLInputElement overrides these.
    def pre_click_activation_state
      nil
    end

    def run_post_click_activation(_state); end

    def restore_pre_click_activation(_state); end

    # Activation behavior: the default action of a non-canceled click (a
    # hyperlink navigates; a submit button submits its form — added later). The
    # default element has none. Called on the *activation target*.
    def activation_behavior(_event); end

    # An element is an "activation target" when it carries its own activation
    # behavior (a hyperlink). Default: no.
    def activation_target?
      false
    end

    # The activation target for a click on this element: the nearest inclusive
    # ancestor that is an activation target, or nil — so clicking a <span> inside
    # an <a href> activates the anchor.
    def activation_target
      node = self
      while node
        return node if node.respond_to?(:activation_target?) && node.activation_target?

        node = node.respond_to?(:parent_element) ? node.parent_element : nil
      end
      nil
    end

    # Run the activation target's activation behavior after a non-canceled click.
    # Shared by Element#click (JS `.click()`) and synthetic clicks
    # (EventSynthesis) so a real default action fires from both paths.
    def __run_click_activation_behavior__(event)
      activation_target&.activation_behavior(event)
    end

    def get_attribute_names
      Backend.attribute_nodes(@__node__).map(&:name)
    end

    # A plain {name => value} snapshot of ALL attributes, for the JS bridge's
    # per-proxy attribute cache (see host_runtime.js): one crossing answers
    # every subsequent getAttribute/hasAttribute until the DOM epoch moves.
    # nil for an element whose attribute lookups are case-SENSITIVE (foreign
    # namespace) — the JS side then keeps the per-call bridge path. Keys are
    # as stored (already lowercased for HTML elements), so a JS-side
    # `name.toLowerCase()` lookup matches get_attribute's normalize_attr_key.
    def __js_attribute_snapshot__
      return nil if case_sensitive_attribute_names?

      # Two attributes can share a qualified name (differing only by namespace);
      # get-an-attribute-by-name returns the FIRST in list order, so keep the
      # first occurrence (Ruby's Array#to_h would keep the last).
      Backend.attribute_nodes(@__node__).each_with_object({}) do |a, snapshot|
        snapshot[a.name] = a.value.to_s unless snapshot.key?(a.name)
      end
    end

    # No real layout engine. By default geometry getters return zeroed rects;
    # when the window opts into approximate geometry (window.approximate_layout)
    # they return non-zero estimates from a cheap pseudo-layout so a site that
    # treats an all-zero rect as "the DOM is broken" can proceed.
    def get_bounding_client_rect
      approximate_layout? ? DOMRect.new(**__internal_approx_box) : DOMRect.new
    end

    def approximate_layout? = !!@document&.default_view&.approximate_layout

    # Estimate {x, y, width, height} (CSS px) without laying out the page: block
    # elements fill the viewport width; inline elements are sized to their text;
    # height is the wrapped line count × a nominal line height. Position is the
    # origin (we don't position elements). Used only when approximate_layout?.
    INLINE_TAGS = %w[a span b i em strong small code label abbr cite q sub sup time mark u s
                     tt var samp kbd bdi bdo wbr big font nobr].freeze
    APPROX_CHAR_PX = 8
    APPROX_LINE_PX = 20

    def __internal_approx_box
      viewport = @document&.default_view&.inner_width.to_i
      viewport = 1280 if viewport <= 0
      text = text_content.to_s
      content_px = text.length * APPROX_CHAR_PX
      if INLINE_TAGS.include?(local_name.to_s.downcase)
        {x: 0, y: 0, width: [content_px, viewport].min, height: text.empty? ? 0 : APPROX_LINE_PX}
      else
        lines = text.empty? ? 0 : [(content_px.to_f / viewport).ceil, 1].max
        {x: 0, y: 0, width: viewport, height: lines * APPROX_LINE_PX}
      end
    end

    def get_client_rects
      return [] unless approximate_layout?

      box = __internal_approx_box
      box[:width].positive? || box[:height].positive? ? [DOMRect.new(**box)] : []
    end

    def request_fullscreen
      @document.__internal_set_fullscreen_element__(self)
      PromiseValue.resolve(@document.default_view, nil)
    end

    # Popover API — show / hide / toggle fire beforetoggle + toggle events
    # (no real visual change). Return values mirror the IDL.
    def show_popover
      toggle_popover_state(true)
      nil
    end

    def hide_popover
      toggle_popover_state(false)
      nil
    end

    def toggle_popover
      new_state = !@__popover_open__
      toggle_popover_state(new_state)
      new_state
    end

    # Ruby block-style listener (in addition to the (type, callable,
    # options) form inherited from EventTarget). Returns the resolved
    # listener so callers can pass it back to remove_event_listener.
    def on(type, &block)
      add_event_listener(type, block)
      block
    end

    # `el[:foo]` / `el[:foo] = ...` bracket shortcut for the JS-style
    # property access pattern. Useful when porting browser-side code
    # to CRuby tests.
    def [](key)
      __js_get__(key.to_s)
    end

    def []=(key, value)
      __js_set__(key.to_s, value)
    end

    def __js_get__(key)
      case key
      when "nodeType"
        1
      when "isConnected"
        is_connected?
      when "scrollTop", "scrollLeft", "clientTop", "clientLeft", "offsetTop", "offsetLeft"
        # Position-ish metrics: 0 (we never lay elements out in the page), as a
        # real browser reports for hidden / pre-paint elements.
        0
      when "clientWidth", "clientHeight", "scrollWidth", "scrollHeight", "offsetWidth", "offsetHeight"
        # Size metrics: 0 by default; a best-effort estimate when the window opts
        # into approximate geometry (see #get_bounding_client_rect).
        if approximate_layout?
          box = __internal_approx_box
          key.end_with?("Width") ? box[:width] : box[:height]
        else
          0
        end
      when "offsetParent"
        nil
      when "popover"
        get_attribute("popover")
      when "children"
        @live_children
      when "childNodes"
        @live_child_nodes
      when "firstChild"
        first_child
      when "lastChild"
        last_child
      when "childElementCount"
        child_element_count
      when "lastElementChild"
        last_element_child
      when "nextSibling"
        next_sibling
      when "previousSibling"
        previous_sibling
      when "nextElementSibling"
        next_element_sibling
      when "previousElementSibling"
        previous_element_sibling
      when "firstElementChild"
        first_element_child
      when "parentElement", "parent"
        # parentElement is null unless the parent is an element (the document /
        # a fragment parent is a parentNode but not a parentElement).
        @__node__.parent&.element? ? wrap_parent(@__node__.parent) : nil
      when "parentNode"
        # `parentNode` is broader than `parentElement` — includes
        # DocumentFragment / Document parents too. Reconcilers use
        # this to find the host before calling replaceChild.
        @__node__.parent && @document.wrap_node(@__node__.parent)
      when "textContent"
        @__node__.text
      when "nodeValue"
        # Per DOM, an Element's nodeValue is always null (only CharacterData /
        # Attr carry a value). Without this it fell through to ABSENT → JS
        # `undefined`, which fails `assert_equals(el.nodeValue, null)`.
        nil
      when "innerHTML"
        inner_html
      when "outerHTML"
        outer_html
      when "tagName"
        tag_name
      when "prefix"
        element_prefix
      when "classList"
        @class_list
      when "relList"
        reflected_token_list("relList", "rel")
      when "htmlFor"
        reflected_token_list("htmlFor", "for")
      when "sandbox"
        reflected_token_list("sandbox", "sandbox")
      when "sizes"
        reflected_token_list("sizes", "sizes")
      when "style"
        @style
      when "dataset"
        @dataset
      when "content"
        template_content
      when "className"
        # DOM reflects the `class` attribute as the `className` string
        # property (space-separated tokens, "" when absent).
        @__node__["class"].to_s
      when "id"
        @__node__["id"].to_s
      when "lang"
        # The `lang` IDL attribute reflects the `lang` content attribute (own
        # value, "" when absent) — not the inherited/computed language.
        @__node__["lang"].to_s
      when "translate"
        # `translate` is a boolean reflecting the element's translation mode,
        # which inherits: translate="yes"/"" → true, "no" → false, else the
        # nearest ancestor's mode; the root defaults to translate (true).
        translate_mode?
      when "hidden", "disabled", "checked", "readOnly", "multiple", "required"
        # Boolean reflected properties — true iff the matching HTML
        # attribute is present. Real DOM normalizes attribute names to
        # lowercase, mapped here too (e.g. `readOnly` ↔ `readonly`).
        @__node__.key?(reflected_attr_name(key))
      when "value"
        # For form elements `value` is a property that defaults to the
        # `value` attribute. We don't model the property/attribute
        # split here — both reads and writes go through the attribute.
        @__node__["value"].to_s
      when "href"
        anchor_href
      when "attributes"
        attributes
      when "namespaceURI"
        namespace_uri
      when "localName"
        local_name
      when "nodeName"
        tag_name
      when "slot"
        slot
      when "role"
        aria_get("role")
      when "accessKeyLabel"
        access_key_label
      when "baseURI"
        base_uri
      when "shadowRoot"
        shadow_root
      when "assignedSlot"
        assigned_slot
      when "ownerDocument"
        @document
      else
        if (elements_attr = aria_elements_attr(key))
          # Plural ARIA element references (`ariaDescribedByElements` ↔
          # `aria-describedby`) — a list of Elements.
          aria_elements_get(elements_attr, key)
        elsif (element_attr = aria_element_attr(key))
          # ARIA element-reference IDL attribute (`ariaActiveDescendantElement`
          # ↔ `aria-activedescendant`) — resolves to an Element or null.
          aria_element_get(element_attr, key)
        elsif (content_attr = aria_content_attr(key))
          # ARIA / role reflected IDL attribute (`ariaLabel` ↔ `aria-label`,
          # `role` ↔ `role`) — a nullable DOMString (null when absent).
          aria_get(content_attr)
        elsif key.start_with?("on") && key.length > 2
          # `el.onXxx` event handler property — the registered callback or nil.
          @on_handlers&.[](event_name_from_on(key))
        elsif key.start_with?("_") || key.include?("$")
          # A framework-private expando key (React stores per-node state under
          # keys like `__reactListeners$<id>` and feature-detects it with
          # `node[key] === undefined`). Real DOM property names never use `_`/`$`,
          # so reporting these *absent* (undefined value, `in` false) is correct
          # JS and doesn't touch real DOM reflection (which WPT pins to null).
          Bridge::ABSENT
        else
          # A genuinely-unknown element property: JS `undefined`, `in` false.
          # (Reflected / ARIA / on* IDL attributes are handled above and keep
          # their nullable-DOMString null semantics.)
          Bridge::ABSENT
        end
      end
    end

    # Anchor / area `href` IDL attribute reflects the attribute resolved
    # against the document base URL (browser semantics). Routers rely on
    # this to compare origins and detect external links.
    def anchor_href
      raw = @__node__["href"]
      return "" if raw.nil?

      win = @document.default_view
      base = win&.location ? win.location.href : ""
      URI.join(base, raw.to_s).to_s
    rescue URI::InvalidURIError, ArgumentError
      raw.to_s
    end

    # `accessKeyLabel` — the assigned access key's platform label. The
    # `accesskey` content attribute is a set of one-code-point candidates; a
    # single valid candidate yields a (modifier-prefixed) label, anything else
    # (empty, or multiple/multi-char tokens) yields the empty string. The exact
    # modifier varies by platform — tests only assert non-empty vs empty.
    def access_key_label
      keys = @__node__["accesskey"].to_s.split(/[ \t\n\f\r]+/).reject(&:empty?)
      return "" unless keys.length == 1 && keys.first.length == 1

      "Alt+#{keys.first.upcase}"
    end

    # The content attribute an ARIA element-reference IDL attribute reflects
    # (`ariaActiveDescendantElement` → "aria-activedescendant",
    # `ariaErrorMessageElement` → "aria-errormessage"), or nil. The IDL name is
    # `aria<Xxx>Element`; the content attribute is "aria-" + <Xxx> lowercased.
    def aria_element_attr(key)
      # Only aria-activedescendant reflects as a SINGULAR element reference; every
      # other ARIA element reference (controls / describedby / details /
      # errormessage / flowto / labelledby / owns) is plural (aria*Elements), so
      # e.g. `ariaErrorMessageElement` must not exist.
      key == "ariaActiveDescendantElement" ? "aria-activedescendant" : nil
    end

    # Read an ARIA element reference: an explicitly-set Element wins; otherwise
    # the content attribute is resolved as an IDREF (the element with that id in
    # this element's tree), or null.
    def aria_element_get(content_attr, key)
      explicit = (@aria_element_refs ||= {})[key]
      if explicit
        # An explicitly-set attr-element is only observable while it stays in a
        # valid scope: a shadow-including descendant of one of this element's
        # shadow-including ancestors. A reference that crosses into a shadow tree
        # (or whose target is reparented out of scope) reads as null.
        return aria_ref_in_valid_scope?(explicit) ? explicit : nil
      end

      idref = @__node__[content_attr].to_s
      return nil if idref.empty?

      aria_find_in_root(idref)
    end

    # WHATWG "reflecting element references" scope check: `attr_element` is valid
    # iff its root is this element's root or a shadow-including-ancestor root
    # (reached by hopping each shadow root to its host). So a same-tree reference
    # and a reference to a shadow-inclusive ancestor are valid, but crossing into
    # a shadow tree (or a sibling/detached scope) is not.
    def aria_ref_in_valid_scope?(attr_element)
      return false unless attr_element.respond_to?(:root_node)

      target_root = attr_element.root_node
      scope = self
      loop do
        root = scope.root_node
        return true if root.equal?(target_root)

        host = root.respond_to?(:host) ? root.host : nil
        return false unless host

        scope = host
      end
    end

    # Set an ARIA element reference: null/undefined clears it and removes the
    # content attribute; an Element stores the explicit reference and sets the
    # content attribute to the empty string (per the reflection spec).
    def aria_element_set(content_attr, key, value)
      refs = (@aria_element_refs ||= {})
      if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
        refs.delete(key)
        remove_attribute(content_attr) if @__node__.key?(content_attr)
      else
        # WebIDL: the value is an `Element?` — a non-Element throws a TypeError.
        raise Bridge::TypeError, "value is not an Element or null" unless value.is_a?(Dommy::Element)

        # set_attribute clears explicit refs via its aria-* hook, so store the
        # new reference afterward.
        set_attribute(content_attr, "")
        refs[key] = value
      end
      nil
    end

    # The content attribute a plural ARIA element-references IDL attribute
    # reflects (`ariaDescribedByElements` → "aria-describedby",
    # `ariaLabelledByElements` → "aria-labelledby"), or nil. The IDL name is
    # `aria<Xxx>Elements`; the content attribute is "aria-" + <Xxx> lowercased.
    def aria_elements_attr(key)
      return nil unless key.is_a?(String) && key.start_with?("aria") && key.end_with?("Elements")
      return nil unless key.length > 12 && key[4] =~ /[A-Z]/

      "aria-#{key[4...-8].downcase}"
    end

    # Read a plural ARIA element references value (a list of Elements): the
    # explicitly-set array wins; otherwise the content attribute is split as a
    # space-separated IDREF list and each resolved (missing ids dropped).
    def aria_elements_get(content_attr, key)
      # null when there are neither explicit elements nor a content attribute.
      return nil if aria_elements_current(content_attr, key).nil?

      # Otherwise a per-property memoized live list, so repeated reads return the
      # [SameObject] (WebIDL requires a stable FrozenArray) while its contents track
      # the current references/IDREFs.
      lists = (@aria_elements_lists ||= {})
      lists[key] ||= LiveNodeList.new { aria_elements_current(content_attr, key) || [] }
    end

    # The current resolved element list for a plural ARIA element reference, or
    # nil when neither explicit elements nor the content attribute are present. An
    # explicitly-set list wins (out-of-scope entries dropped); otherwise the
    # content attribute is split as space-separated IDREFs and each resolved.
    def aria_elements_current(content_attr, key)
      explicit = (@aria_elements_refs ||= {})[key]
      return explicit.select { |el| aria_ref_in_valid_scope?(el) } if explicit
      return nil unless @__node__.key?(content_attr)

      @__node__[content_attr].to_s.split(/[ \t\n\f\r]+/).reject(&:empty?).filter_map do |id|
        aria_find_in_root(id)
      end
    end

    # Resolve an ARIA IDREF within this element's tree ROOT (its topmost
    # ancestor) rather than the document — so references keep working when the
    # subtree is disconnected from the document.
    def aria_find_in_root(id)
      root = @__node__
      root = root.parent while root.parent && !root.parent.is_a?(Backend.document_class)
      node = ([root] + root.css("*").to_a).find { |n| n["id"].to_s == id }
      node && @document.wrap_node(node)
    end

    # Set a plural ARIA element references value: null/undefined clears it and
    # removes the content attribute; an array of Elements is stored and the
    # content attribute is set to the empty string.
    def aria_elements_set(content_attr, key, value)
      refs = (@aria_elements_refs ||= {})
      if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
        refs.delete(key)
        remove_attribute(content_attr) if @__node__.key?(content_attr)
      else
        # WebIDL: the value is a `sequence<Element>?` — a non-array, or an array
        # containing a non-Element, throws a TypeError.
        unless value.is_a?(Array) && value.all? { |el| el.is_a?(Dommy::Element) }
          raise Bridge::TypeError, "value is not a sequence of Elements"
        end

        set_attribute(content_attr, "")
        refs[key] = value.dup
      end
      nil
    end

    # Drop any explicit ARIA element reference (singular or plural) whose content
    # attribute was just set directly (so the IDL getter re-resolves the IDREF).
    def clear_aria_element_ref_for(content_attr)
      @aria_element_refs&.delete_if { |key, _| aria_element_attr(key) == content_attr }
      @aria_elements_refs&.delete_if { |key, _| aria_elements_attr(key) == content_attr }
    end

    # The content attribute a role/ARIA IDL attribute reflects, or nil for a
    # non-ARIA key. `role` → "role"; `ariaXxx` → "aria-" + the rest, lowercased
    # with humps removed (`ariaAutoComplete` → "aria-autocomplete",
    # `ariaColIndexText` → "aria-colindextext").
    def aria_content_attr(key)
      return "role" if key == "role"
      return nil unless key.is_a?(String) && key.length > 4 && key.start_with?("aria")
      return nil unless key[4] =~ /[A-Z]/

      "aria-#{key[4..].downcase}"
    end

    # Read a reflected nullable DOMString: the content attribute value, or nil
    # (→ JS null) when the attribute is absent.
    def aria_get(content_attr)
      @__node__.key?(content_attr) ? @__node__[content_attr].to_s : nil
    end

    # Write a reflected nullable DOMString: null / undefined removes the content
    # attribute; any other value is ToString-coerced and set.
    def aria_set(content_attr, value)
      if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
        remove_attribute(content_attr) if @__node__.key?(content_attr)
      else
        set_attribute(content_attr, value.to_s)
      end
      nil
    end

    # Map a JS boolean property name to its underlying HTML attribute.
    # HTML attribute names are lowercase; the DOM property may be
    # camelCase (`readOnly` → `readonly`).
    def reflected_attr_name(key)
      {"readOnly" => "readonly"}.fetch(key, key)
    end

    # The element's translation mode (HTML `translate`): the nearest ancestor-or-
    # self with a valid translate attribute decides ("yes"/"" → true, "no" →
    # false); with none, the root default is translate (true).
    def translate_mode?
      node = self
      while node
        attr = node.respond_to?(:get_attribute) ? node.get_attribute("translate") : nil
        unless attr.nil?
          value = attr.to_s.downcase
          return true if value == "yes" || value.empty?
          return false if value == "no"
          # An invalid value inherits — keep walking up.
        end
        node = node.respond_to?(:parent_element) ? node.parent_element : nil
      end
      true
    end

    def __js_set__(key, value)
      case key
      when "textContent"
        self.text_content = value
      when "innerHTML"
        self.inner_html = value
      when "outerHTML"
        # [CEReactions, LegacyNullToEmptyString] DOMString — null becomes "".
        self.outer_html = value.nil? ? "" : value.to_s
      when "hidden", "disabled", "checked", "readOnly", "multiple", "required"
        # Boolean reflected property — funnel through set_attribute /
        # remove_attribute so MutationObserver attribute records fire.
        name = reflected_attr_name(key)
        if value
          set_attribute(name, "")
        elsif @__node__.key?(name)
          remove_attribute(name)
        end

      when "style"
        # WHATWG [PutForwards=cssText]: `el.style = "..."` forwards to
        # `el.style.cssText`, reparsing and rewriting the `style` attribute.
        # Handling it here stops the bridge from stashing a string expando that
        # would shadow the CSSStyleDeclaration getter.
        @style.css_text = value.nil? ? "" : value.to_s
      when "lang"
        set_attribute("lang", value.to_s)
      when "translate"
        # The setter is a plain boolean → "yes" / "no".
        set_attribute("translate", value ? "yes" : "no")
      when "className"
        set_attribute("class", value.to_s)
      when "classList"
        # WHATWG [PutForwards=value]: `el.classList = x` forwards to
        # `el.classList.value = x` (set the class attribute). Handling it here
        # (instead of letting the write fall through as unhandled) stops the JS
        # bridge from stashing a string expando that would shadow the classList
        # getter for the rest of the element's life.
        set_attribute("class", value.to_s)
      when "id"
        set_attribute("id", value.to_s)
      when "value"
        set_attribute("value", value.to_s)
      when "slot"
        set_attribute("slot", value.to_s)
      when "role"
        aria_set("role", value)
      else
        if (elements_attr = aria_elements_attr(key))
          # Plural ARIA element references setter (list of Elements).
          aria_elements_set(elements_attr, key, value)
        elsif (element_attr = aria_element_attr(key))
          # ARIA element-reference IDL attribute setter.
          aria_element_set(element_attr, key, value)
        elsif (content_attr = aria_content_attr(key))
          # ARIA / role reflected nullable DOMString (null/undefined → remove).
          aria_set(content_attr, value)
        elsif key.start_with?("on") && key.length > 2
          # `el.onXxx = fn` registers fn as a single named handler; nil removes.
          set_on_handler(event_name_from_on(key), value)
        else
          # Not a known DOM property — tell the JS host to keep it as a
          # JS-side expando (so object/instance fields keep their identity).
          Bridge::UNHANDLED
        end
      end
    end

    include Bridge::Methods
    js_methods %w[
      getAttribute setAttribute hasAttribute removeAttribute getAttributeNames closest
      getAttributeNS setAttributeNS hasAttributeNS removeAttributeNS getAttributeNodeNS setAttributeNodeNS
      querySelector querySelectorAll getElementsByClassName getElementsByTagName getElementsByTagNameNS
      insertAdjacentElement insertAdjacentHTML insertAdjacentText toggleAttribute matches webkitMatchesSelector
      toString getAttributeNode setAttributeNode removeAttributeNode focus blur attachShadow
      addEventListener removeEventListener dispatchEvent appendChild insertBefore removeChild
      replaceChild cloneNode append prepend replaceChildren before after getInnerHTML getHTML
      remove replaceWith click getBoundingClientRect getClientRects scrollIntoView scroll
      scrollTo scrollBy requestFullscreen showPopover hidePopover togglePopover isEqualNode
      hasChildNodes hasAttributes getRootNode normalize contains
      compareDocumentPosition isSameNode lookupNamespaceURI lookupPrefix isDefaultNamespace
      __internal_computed_role__ __internal_computed_label__ __internal_computed_description__
    ]
    def __js_call__(method, args)
      case method
      when "__internal_computed_role__"
        computed_role
      when "__internal_computed_label__"
        computed_label
      when "__internal_computed_description__"
        computed_description
      when "hasChildNodes"
        has_child_nodes?
      when "hasAttributes"
        has_attributes?
      when "getAttribute"
        get_attribute(args[0])
      when "setAttribute"
        set_attribute(args[0], args[1])
      when "hasAttribute"
        has_attribute?(args[0])
      when "removeAttribute"
        remove_attribute(args[0])
      when "getAttributeNS"
        get_attribute_ns(args[0], args[1])
      when "setAttributeNS"
        set_attribute_ns(args[0], args[1], args[2])
      when "hasAttributeNS"
        has_attribute_ns?(args[0], args[1])
      when "removeAttributeNS"
        remove_attribute_ns(args[0], args[1])
      when "getAttributeNodeNS"
        get_attribute_node_ns(args[0], args[1])
      when "setAttributeNodeNS"
        set_attribute_node(args[0])
      when "getAttributeNames"
        get_attribute_names
      when "closest"
        raise Bridge::TypeError, "1 argument required, but only 0 present" if args.empty?

        closest(args[0])
      when "querySelector"
        query_selector(Internal.css_query_arg!(args))
      when "querySelectorAll"
        query_selector_all(Internal.css_query_arg!(args))
      when "getElementsByClassName"
        get_elements_by_class_name(args[0])
      when "getElementsByTagNameNS"
        get_elements_by_tag_name_ns(args[0], args[1])
      when "getElementsByTagName"
        get_elements_by_tag_name(args[0])
      when "getRootNode"
        get_root_node(args[0])
      when "normalize"
        normalize
      when "insertAdjacentElement"
        insert_adjacent_element(args[0], args[1])
      when "insertAdjacentHTML"
        insert_adjacent_html(args[0], args[1])
      when "insertAdjacentText"
        insert_adjacent_text(args[0], args[1])
      when "toggleAttribute"
        toggle_attribute(args[0], args[1])
      when "matches", "webkitMatchesSelector"
        raise Bridge::TypeError, "1 argument required, but only 0 present" if args.empty?

        # WebIDL DOMString: a null selector coerces to "null" (so `<null>` matches),
        # undefined to "undefined". webkitMatchesSelector is a legacy alias.
        matches?(args[0].nil? ? "null" : args[0])
      when "isEqualNode"
        is_equal_node(args[0])
      when "isSameNode"
        is_same_node(args[0])
      when "compareDocumentPosition"
        compare_document_position(args[0])
      when "lookupNamespaceURI"
        lookup_namespace_uri(args[0])
      when "lookupPrefix"
        lookup_prefix(args[0])
      when "isDefaultNamespace"
        is_default_namespace(args[0])
      when "contains"
        contains?(args[0])
      when "toString"
        to_s
      when "getAttributeNode"
        get_attribute_node(args[0])
      when "setAttributeNode"
        set_attribute_node(args[0])
      when "removeAttributeNode"
        remove_attribute_node(args[0])
      when "focus"
        focus
      when "blur"
        blur
      when "attachShadow"
        attach_shadow(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "appendChild"
        append_child(args[0])
      when "insertBefore"
        validate_insert_before_ref!(args)
        insert_before(args[0], args[1])
      when "removeChild"
        remove_child(args[0])
      when "replaceChild"
        replace_child(args[0], args[1])
      when "cloneNode"
        clone_node(args[0])
      when "append"
        append(*args)
      when "prepend"
        prepend(*args)
      when "replaceChildren"
        replace_children(*args)
      when "before"
        child_node_before(args)
      when "after"
        child_node_after(args)
      when "getInnerHTML", "getHTML"
        inner_html
      when "remove"
        remove
        Bridge::UNDEFINED # ChildNode#remove is void -> JS undefined, not null
      when "replaceWith"
        child_node_replace_with(args)
      when "click"
        click
      when "getBoundingClientRect"
        get_bounding_client_rect
      when "getClientRects"
        get_client_rects
      when "scrollIntoView", "scroll", "scrollTo", "scrollBy"
        record_scroll(method, args)
      when "requestFullscreen"
        request_fullscreen
      when "showPopover"
        show_popover
      when "hidePopover"
        hide_popover
      when "togglePopover"
        toggle_popover
      else
        nil
      end
    end

    def get_attribute(name)
      return nil if name.nil?

      @__node__[normalize_attr_key(name)]
    end

    def set_attribute(name, value)
      return nil if name.nil?

      # WHATWG: a qualifiedName not matching the Name production throws.
      # The WPT corpus exercises only the empty string here (other shapes
      # like "0"/":"/"invalid^Name" are deliberately treated as valid).
      raise DOMException::InvalidCharacterError, "empty attribute name" if name.to_s.empty?

      # A case-sensitive element (non-HTML namespace, or any element in a non-HTML
      # document) must preserve the attribute name's case, but a plain `node[name]=`
      # write goes through the HTML backend which ASCII-lowercases it. Route an
      # upper-cased name through the case-preserving namespace setter (null
      # namespace) to keep the case; lower-case names take the fast path unchanged.
      qn = name.to_s
      if case_sensitive_attribute_names? && qn.match?(/[A-Z]/)
        old = Backend.get_attribute_ns(@__node__, nil, qn)
        Backend.set_attribute_ns(@__node__, nil, nil, qn, qn, value.to_s)
        @document.notify_attribute_mutation(target_node: @__node__, attribute_name: qn, old_value: old)
        return nil
      end

      key = normalize_attr_key(name)
      old = @__node__[key]
      @__node__[key] = value.to_s
      # A direct write to an `aria-*` IDREF attribute drops any explicitly-set
      # element reference, so the IDL getter re-resolves the new IDREF.
      clear_aria_element_ref_for(key) if key.start_with?("aria-")
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: key, old_value: old)
      nil
    end

    def has_attribute?(name)
      return false if name.nil?

      @__node__.key?(normalize_attr_key(name))
    end

    def remove_attribute(name)
      return nil if name.nil?

      key = normalize_attr_key(name)
      return nil unless @__node__.key?(key)

      old = @__node__[key]
      # Detach the cached Attr (caching its value) *before* the backend drop, so a
      # held reference keeps the value it had when removed and reports
      # `ownerElement === null` (so it's no longer "in use"). An attribute set via
      # setAttributeNS may carry a namespace, so evict by the removed node's real
      # (namespace, localName) rather than assuming the null namespace.
      if @attributes
        removed = Backend.attribute_nodes(@__node__).find { |a| Backend.attribute_ns_info(a)[:qualified_name] == key }
        info = removed && Backend.attribute_ns_info(removed)
        @attributes.__internal_evict__(info ? info[:namespace_uri] : nil, info ? info[:local_name] : key)
      end
      @__node__.remove_attribute(key)
      # Removing an `aria-*` IDREF attribute also clears any explicitly-set
      # element reference (the IDL getter then returns null).
      clear_aria_element_ref_for(key) if key.start_with?("aria-")
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: key, old_value: old)
      nil
    end

    # ----- Namespaced attributes (DOM *AttributeNS) -----

    def get_attribute_ns(namespace, local_name)
      return nil if local_name.nil?

      Backend.get_attribute_ns(@__node__, namespace_arg(namespace), local_name.to_s)
    end

    def has_attribute_ns?(namespace, local_name)
      return false if local_name.nil?

      Backend.has_attribute_ns?(@__node__, namespace_arg(namespace), local_name.to_s)
    end

    def set_attribute_ns(namespace, qualified_name, value)
      ns, prefix, local = Internal::Namespaces.validate_and_extract(namespace, qualified_name)
      old = Backend.get_attribute_ns(@__node__, ns, local)
      Backend.set_attribute_ns(@__node__, ns, prefix, local, qualified_name.to_s, value.to_s)
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: local, old_value: old, namespace: ns)
      nil
    end

    def remove_attribute_ns(namespace, local_name)
      return nil if local_name.nil?

      ns = namespace_arg(namespace)
      local = local_name.to_s
      old = Backend.get_attribute_ns(@__node__, ns, local)
      @attributes&.__internal_evict__(ns, local)
      Backend.remove_attribute_ns(@__node__, ns, local)
      if old
        @document.notify_attribute_mutation(target_node: @__node__, attribute_name: local, old_value: old, namespace: ns)
      end
      nil
    end

    def get_attribute_node_ns(namespace, local_name)
      attributes.get_named_item_ns(namespace, local_name)
    end

    def closest(selector)
      return nil if selector.nil?
      ast = Internal::SelectorParser.parse!(selector)
      Internal::SelectorMatcher.closest(self, ast)
    end

    # Map Nokogiri's selector errors to spec behavior:
    # - a CSS *parse* error ("unexpected … after …") means the selector is
    #   syntactically invalid → SyntaxError (querySelector/closest must throw);
    # - an "Unregistered function" means a valid pseudo Nokogiri compiled but
    #   can't evaluate (`:hover`, `:invalid`, …) → degrade to matching nothing.
    def with_selector_errors(selector, &block)
      Internal.with_selector_errors(selector, &block)
    end

    # Web Animations: start an animation on this element.
    # Returns the new Animation. Dommy doesn't interpolate; the
    # animation simply transitions through the `playState` lifecycle,
    # finishing via `scheduler.advance_time(duration)` or an
    # explicit `animation.finish`.
    def animate(keyframes, options = nil)
      effect = KeyframeEffect.new(self, keyframes, options)
      animation = Animation.new(effect, nil, window: @document.default_view)
      @__animations ||= []
      @__animations << animation
      animation.play
      animation
    end

    def get_animations(_options = nil)
      (@__animations ||= []).dup
    end

    alias getAnimations get_animations

    def query_selector(selector)
      return nil if selector.nil?
      # The empty string is not a valid selector (an explicit DOMString "" is a
      # SyntaxError; `null` coerces to "null" and is handled above as nil).
      sel = selector.to_s
      doc = owner_document
      key = [object_id, :first, sel]
      if doc && (hit = doc.__internal_scoped_query_get(key))
        return hit.first # [result] tuple — distinguishes a cached nil match from a miss
      end

      ast = Internal::SelectorParser.parse!(selector)
      result = Internal::SelectorMatcher.query_first(self, ast, scope: self)
      doc&.__internal_scoped_query_set(key, [result])
      result
    end

    def query_selector_all(selector)
      return NodeList.new if selector.nil?
      sel = selector.to_s
      doc = owner_document
      key = [object_id, :all, sel]
      if doc && (hit = doc.__internal_scoped_query_get(key))
        return NodeList.new(hit) # NodeList.new copies, so the cached array is never aliased
      end

      ast = Internal::SelectorParser.parse!(selector)
      matches = Internal::SelectorMatcher.query(self, ast, scope: self)
      doc&.__internal_scoped_query_set(key, matches)
      NodeList.new(matches)
    end

    # XPath queries scoped to this element, returning wrapped nodes.
    def at_xpath(expression)
      node = @__node__.at_xpath(expression)
      node && @document.wrap_node(node)
    end

    def xpath(expression)
      @__node__.xpath(expression).map { |node| @document.wrap_node(node) }
    end

    # The XPath string locating this element in its document.
    def path
      @__node__.path
    end

    def insert_before(child, reference)
      coerce_node_argument!(child)
      # WHATWG: if the reference child is the node being inserted, the reference
      # becomes that node's next sibling, so "insert x before x" doesn't move x.
      reference = wrapped_next_sibling(reference) if same_wrapped_node?(reference, child)
      ensure_pre_insertion_validity!(child, reference)
      nodes = detach_dom_nodes(child)
      if reference.nil? || (defined?(Bridge::UNDEFINED) && reference.equal?(Bridge::UNDEFINED))
        append_dom_nodes(nodes)
      else
        # The reference is guaranteed (by validity) to be a child here. Insert in
        # order before it: each new node becomes its immediate previous sibling,
        # so forward iteration yields the original order (reverse would flip a
        # multi-node fragment).
        ref_node = unwrap_dom_node(reference)
        nodes.each { |node| ref_node.add_previous_sibling(node) }
      end

      notify_child_list(added: nodes)
      child
    end

    def remove_child(child)
      coerce_node_argument!(child)
      node = unwrap_dom_node(child)
      unless node&.parent == @__node__
        raise DOMException::NotFoundError, "node is not a child of this element"
      end

      @document.remove_node_with_notify(node)
      child
    end

    # `node.replaceChild(newChild, oldChild)` — required for
    # in-place item updates in list reconcilers. Inserts newChild
    # where oldChild was, then unlinks oldChild. Notifies
    # MutationObserver of both changes in one record so observers
    # see the swap atomically.
    def replace_child(new_child, old_child)
      coerce_node_argument!(new_child)
      coerce_node_argument!(old_child)
      # replaceChild shares the pre-insertion checks (ancestor, node type,
      # doctype placement); the reference child here is old_child, so step 3
      # also enforces that it is actually a child (NotFoundError otherwise).
      ensure_pre_insertion_validity!(new_child, old_child)
      old_node = unwrap_dom_node(old_child)

      # Capture the insertion point (old's next sibling) before detaching the new
      # child, which may itself be old (replaceChild(x, x)) or old's sibling.
      # WHATWG: if that reference child IS the node being inserted (new_child is
      # old's next sibling), advance it to new_child's next sibling so the node
      # lands in old's slot rather than being appended.
      anchor = old_node.next_sibling
      new_bn = unwrap_dom_node(new_child)
      anchor = anchor.next_sibling if anchor && new_bn && anchor == new_bn
      new_nodes = detach_dom_nodes(new_child)
      anchor = nil if anchor && anchor.parent != @__node__

      # detach_dom_nodes already removed old when new_child === old_child; only
      # unlink (and record the removal) when old is still attached.
      removed = []
      if old_node.parent == @__node__
        old_node.unlink
        removed = [old_node]
      end

      if anchor
        new_nodes.each { |node| anchor.add_previous_sibling(node) }
      else
        new_nodes.each { |node| @__node__.add_child(node) }
      end
      notify_child_list(added: new_nodes, removed: removed)
      old_child
    end

    def clone_node(deep_arg)
      # Copy the node in place via the backend's deep clone, NOT by re-parsing
      # to_html as a fragment: the HTML fragment parser unwraps `<body>` /
      # `<head>` / `<html>`, so cloning a body would produce its children, not a
      # body element (which broke Turbo's snapshot cache — it clones the body and
      # restores it via documentElement.replaceChild on back/forward). The clone
      # preserves the element's namespace and attributes (createElement would
      # lose the namespace).
      copy = Backend.clone_node(@__node__, deep: deep_arg)
      # The backend (lexbor, HTML-only) doesn't retain the createElementNS
      # prefix/local/qualified-name/namespace, so rebuild the clone's wrapper from
      # that metadata — routing the interface class by the local name and
      # reapplying tagName/localName/prefix/namespaceURI. Otherwise the clone loses
      # its prefix/case and resolves to HTMLUnknownElement.
      if @__ns_qname
        @document.wrap_cloned_element_ns(copy, @__ns_uri, @__ns_prefix, @__ns_local, @__ns_qname)
      else
        @document.wrap_node(copy)
      end
    end

    # Test inspector for scroll calls (no real layout to scroll).
    def __test_scroll_log__
      @scroll_log ||= []
    end

    # ---- Internal helpers (single private section) ----
    private

    # blur (at the element) then focusout (bubbling), per UI Events order.
    def fire_focus_out(element, new_target)
      element.dispatch_event(Dommy::FocusEvent.new("blur", "composed" => true, "relatedTarget" => new_target))
      element.dispatch_event(Dommy::FocusEvent.new("focusout",
        "bubbles" => true, "composed" => true, "relatedTarget" => new_target))
      nil
    end

    # A disabled form control cannot be focused (HTML focusability). Other
    # elements are all treated as focusable — no layout means no visibility /
    # tabindex modelling.
    def disabled_form_control?
      %w[input button select textarea].include?(local_name) && has_attribute?("disabled")
    end

    def attribute_signature
      Backend.attribute_nodes(@__node__).map { |a| [a.name, a.value] }.sort
    end

    # on* event-handler property helpers.
    # Attribute-key / child-wrapping / event-parent helpers.
    def normalize_attr_key(name)
      s = name.to_s
      case_sensitive_attribute_names? ? s : s.downcase
    end

    # WebIDL nullable-DOMString namespace argument (*AttributeNS): JS null and
    # undefined, and the empty string, all denote the null namespace.
    def namespace_arg(namespace)
      return nil if namespace.nil? || namespace.equal?(Bridge::UNDEFINED)

      s = namespace.to_s
      s.empty? ? nil : s
    end

    def element_children
      @__node__.element_children.each_with_object([]) do |node, out|
        wrapped = @document.wrap_node(node)
        out << wrapped if wrapped
      end
    end

    def wrap_parent(node)
      @document.wrap_node(node)
    end

    def __internal_event_parent__
      parent_node = @__node__.parent
      # If our Nokogiri parent is a shadow tree's backing fragment,
      # the bubble path's next stop is the ShadowRoot itself — not
      # the bare Fragment wrapper. The ShadowRoot's __internal_event_parent__
      # will return nil (composed events route to host explicitly).
      if parent_node.is_a?(Backend.document_fragment_class)
        sr = @document.__internal_shadow_root_for_fragment__(parent_node)
        return sr if sr
      end

      parent = wrap_parent(parent_node)
      parent || @document
    end

    def template_content
      return nil unless @__node__.name == "template"

      @document.template_content_fragment(self)
    end

    # Attribute name handling depends on the element's namespace:
    # - HTML: case-insensitive (browser DOM stores everything lowercase).
    # - SVG / other XML: case-sensitive (`viewBox` ≠ `viewbox`).
    # Subclasses with a known namespace override `case_sensitive_attribute_names?`
    # to flip the behavior. Generic Element nodes inspect the namespace
    # URI directly.
    # Attribute qualified names are ASCII-lowercased (case-insensitive) only for an
    # element in the HTML namespace within an HTML document; every other case — a
    # non-HTML (or null) namespace, or any element in a non-HTML document —
    # preserves case (WHATWG "set/get/has attribute" lowercasing condition).
    def case_sensitive_attribute_names?
      !(namespace_uri == "http://www.w3.org/1999/xhtml" && @document.html_document?)
    end

    # Insertion / scroll / popover helpers.
    def append_dom_nodes(nodes)
      nodes.each { |node| @__node__.add_child(node) }
    end

    # ParentNode hook: Element enforces the no-cycle hierarchy check that
    # Fragment / ShadowRoot skip.
    def check_insertion!(child)
      check_hierarchy!(child)
    end

    # Raise HierarchyRequestError when the proposed insertion would
    # produce a cycle (inserting an ancestor as a descendant of
    # itself). Strings and Fragments are always safe.
    def check_hierarchy!(child)
      return unless child.respond_to?(:__dommy_backend_node__)

      node = child.__dommy_backend_node__
      return unless node.is_a?(Backend.node_class)

      if node == @__node__ || @__node__.ancestors.any? { |a| a == node }
        raise(
          DOMException::HierarchyRequestError,
          "Cannot insert a node as a descendant of itself"
        )
      end
    end

    def detach_for_insert(value)
      detach_dom_nodes(value).first
    end

    # Whether two wrapped values back the same backend node (used to detect
    # `insertBefore(x, x)`).
    def same_wrapped_node?(a, b)
      an = a.respond_to?(:__dommy_backend_node__) ? a.__dommy_backend_node__ : nil
      bn = b.respond_to?(:__dommy_backend_node__) ? b.__dommy_backend_node__ : nil
      !an.nil? && an == bn
    end

    # The wrapped next sibling of a wrapped reference node (nil at end of list).
    def wrapped_next_sibling(reference)
      nk = reference.respond_to?(:__dommy_backend_node__) ? reference.__dommy_backend_node__&.next : nil
      nk && @document.wrap_node(nk)
    end

    def unwrap_dom_node(value)
      return value.__dommy_backend_node__ if value.respond_to?(:__dommy_backend_node__)

      nil
    end

    def matches_selector?(node, selector)
      return false if node.nil?

      # A valid pseudo the backend can't evaluate (`:active`, `:invalid`, …)
      # degrades to not-matching ([] from the rescue) — the same policy as
      # the query methods.
      result = with_selector_errors(selector) { matches_selector_uncaught?(node, selector) }
      result == [] ? false : result
    end

    def matches_selector_uncaught?(node, selector)
      return node.document.css(selector).any? { |candidate| candidate == node } unless node.respond_to?(:matches?)

      # A detached node (no parent) breaks Nokogiri's `matches?`, which evaluates
      # `ancestors.last.search(selector)` — `ancestors.last` is nil with no
      # ancestors. matches() ignores connectivity (a disconnected element still
      # matches a selector it satisfies — e.g. Stimulus checks a just-removed
      # outlet element), so give a parentless node a transient fragment root,
      # then restore its detached state.
      if node.respond_to?(:parent) && node.parent.nil? &&
         node.respond_to?(:document) && node.document.respond_to?(:fragment)
        return matches_detached_node?(node, selector)
      end

      node.matches?(selector)
    end

    # Match a parentless node by wrapping it in a throwaway fragment so the
    # backend's `matches?` has an ancestor root, then unlinking to leave the
    # node detached (and its parentNode unchanged) as it was. `fragment("")`
    # (not the no-arg form) is backend-agnostic — Makiri's takes a source string.
    def matches_detached_node?(node, selector)
      node.document.fragment("").add_child(node)
      node.matches?(selector)
    ensure
      node.unlink
    end

    # No real layout — record the scroll request so tests can assert it.
    def record_scroll(name, args)
      @scroll_log ||= []
      @scroll_log << [name, args]
      nil
    end

    # Popover state — modern HTML pattern. `show`/`hide`/`toggle`
    # fire `beforetoggle` and `toggle` events (no real visual change).
    def toggle_popover_state(open)
      old_state = @__popover_open__ ? "open" : "closed"
      new_state = open ? "open" : "closed"
      return if old_state == new_state

      dispatch_event(
        CustomEvent.new(
          "beforetoggle",
          "detail" => {"oldState" => old_state, "newState" => new_state}
        )
      )
      @__popover_open__ = open
      dispatch_event(
        CustomEvent.new(
          "toggle",
          "detail" => {"oldState" => old_state, "newState" => new_state}
        )
      )
    end
  end
end
