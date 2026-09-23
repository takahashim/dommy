# frozen_string_literal: true

module Dommy
  # Text, comments, CDATA sections and processing instructions —
  # the nodes whose content is a string rather than a subtree.
  #
  # Lived in element.rb, which is for Element.
  # CharacterData base — TextNode and CommentNode share the data /
  # nodeValue / textContent API and `remove` / `cloneNode` semantics.
  class CharacterDataNode
    include Node
    include EventTarget
    # `before` / `after` / `replaceWith` (+ their argument coercion) — the same
    # spec-correct implementation Element uses, minus appendChild/insertBefore.
    include Internal::ChildNode
    include Internal::LeafNode

    # The owning Dommy document (as Element exposes), so cross-document adoption
    # checks work for text/comment nodes too.
    attr_reader :document

    def __dommy_backend_node__ = @__node__

    # EventTarget needs a parent for event propagation; a character-data node
    # bubbles to its parent element.
    def __internal_event_parent__
      @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    # Text.splitText / CharacterData split: break the node at `offset` (a UTF-16
    # code unit index), keeping [0, offset) here and returning a new sibling node
    # with the remainder.
    def split_text(offset)
      off = offset.to_i
      full = @__node__.content
      length = utf16_length(full)
      raise DOMException::IndexSizeError, "offset #{off} is out of bounds" if off.negative? || off > length

      count = length - off
      new_node = @document.create_text_node(utf16_slice(full, off, count))
      new_bn = new_node.__dommy_backend_node__
      parent = @__node__.parent
      if parent
        # Step 7.1 — insert the new node right after self. Its live range steps
        # run here, where the algorithm puts them; its childList RECORD is
        # queued at the very end instead (see below).
        # WHATWG "split a Text node" step 7.1 inserts the new node right after
        # self, so insert step 5 runs first, against self's next sibling.
        @document.__internal_ranges_will_insert__(parent, @__node__.next, 1)
        @__node__.add_next_sibling(new_bn)
        # Live ranges past the split point move to the tail node (the generic
        # insert step above already shifted boundaries sitting further along).
        # Step 7 only runs for a node that HAS a parent: splitting a detached
        # node leaves every boundary on the node itself, to be clamped by the
        # truncation below.
        @document.__internal_ranges_split_text__(self, off, new_node)
      end
      # Step 8 — "replace data with node, offset, count, the empty string": the
      # truncation is a data replacement, so it carries the replace-data live
      # range rules (the ones that clamp a boundary in a detached node).
      write_data(utf16_slice(full, 0, off))
      @document.__internal_ranges_replaced_data__(self, off, count, 0)
      # The one place Dommy queues MutationRecords out of algorithm order. Read
      # literally, the insertion (step 7.1) precedes the data replacement (step
      # 8), so the records would be childList then characterData. Every shipping
      # engine emits them the other way round: Blink's Text::splitText calls
      # DidModifyData before InsertBefore, WebCore matches it, and Gecko's
      # Text::SplitText not only matches but says in a comment that nsRange
      # DEPENDS on the data notification preceding the insertion. Confirmed by
      # running the same script in all three — Chromium 141, WebKitGTK 2.52.6
      # and Firefox all answer [characterData, childList], while all three
      # answer [childList, characterData] for those same two mutations performed
      # explicitly, so this is specific to splitText and not a general
      # reordering. Only the record order moves: the tree and every live range
      # boundary still follow the steps exactly as written.
      # https://github.com/takahashim/dommy/issues/23
      @document.notify_child_list_mutation(target_node: parent, added_nodes: [new_bn], removed_nodes: []) if parent
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
      # Assigning `data` is "replace data" over the whole node, so a live range
      # boundary inside it clamps to the start rather than dangling past the end.
      old_length = utf16_length(@__node__.content)
      write_data(value)
      @document.__internal_ranges_replaced_data__(self, 0, old_length, utf16_length(@__node__.content))
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
    # Range boundary offsets mean the same thing, so the conversion itself lives
    # in Internal::Utf16 and both share it.
    def utf16_length(str)
      Internal::Utf16.length(str)
    end

    def utf16_slice(str, offset, count)
      Internal::Utf16.slice(str, offset, count)
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
      inserted = dom_string(value)
      write_data(utf16_slice(s, 0, o) + inserted + utf16_slice(s, o + c, len - (o + c)))
      # Live ranges whose boundary sits in (or past) the replaced run follow it.
      @document.__internal_ranges_replaced_data__(self, o, c, utf16_length(inserted))
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
      when "appendChild"
        append_child(args[0])
      when "insertBefore"
        insert_before(args[0], args[1])
      when "replaceChild"
        replace_child(args[0], args[1])
      when "removeChild"
        remove_child(args[0])
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

    # WHATWG Text.wholeText — the concatenated data of this node together with
    # its contiguous, logically-adjacent Text / CDATASection siblings (node
    # types 3 and 4), in document order.
    def whole_text
      run = [@__node__]
      prev = @__node__.previous
      while prev && [3, 4].include?(prev.node_type)
        run.unshift(prev)
        prev = prev.previous
      end
      nxt = @__node__.next
      while nxt && [3, 4].include?(nxt.node_type)
        run.push(nxt)
        nxt = nxt.next
      end
      run.map { |bn| bn.content.to_s }.join
    end

    def __js_get__(key)
      return whole_text if key == "wholeText"

      super
    end

    # Node.cloneNode. CharacterData has no children, so `deep` decides nothing:
    # the copy is a new node of the SAME interface carrying the same data, owned
    # by this node's document. Each subclass builds its own kind — a CDATASection
    # that cloned to a Text would be the wrong node.
    def clone_node(_deep = false)
      @document.create_text_node(@__node__.text)
    end

    # Own __js_call__ methods, on top of CharacterDataNode's.
    js_methods %w[cloneNode]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        clone_node(args.first)
      else
        super
      end
    end
  end

  # CDATASection — a Text subtype (nodeType 4). CharacterData methods and the
  # "#cdata-section" nodeName come from CharacterDataNode via node_type.

  # CDATASection — a Text subtype (nodeType 4). CharacterData methods and the
  # "#cdata-section" nodeName come from CharacterDataNode via node_type.
  class CDATASectionNode < TextNode
    def node_type
      4
    end

    def clone_node(_deep = false)
      @document.create_cdata_section(@__node__.content)
    end
  end

  class CommentNode < CharacterDataNode
    def node_type
      8
    end

    def clone_node(_deep = false)
      @document.create_comment(@__node__.content)
    end

    # Own __js_call__ methods, on top of CharacterDataNode's.
    js_methods %w[cloneNode]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        clone_node(args.first)
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

    def clone_node(_deep = false)
      @document.create_processing_instruction(@__node__.target, @__node__.content)
    end

    # Own __js_call__ methods, on top of CharacterDataNode's.
    js_methods %w[cloneNode]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        clone_node(args.first)
      else
        super
      end
    end
  end

  # (`LiveChildren` removed — `el.children` now returns a
  # `Dommy::HTMLCollection` initialized with a re-evaluating block.)
end
