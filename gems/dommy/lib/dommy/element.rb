# frozen_string_literal: true

require "uri"

require_relative "parser"

module Dommy
  # An element: its attributes, its place in the tree, the selectors it matches
  # and how it serializes.
  #
  # The four Internal mixins below are subjects that were Element's without
  # being about being an element. The class body was 2217 lines before they
  # moved out; each one is now readable without the other three.
  class Element
    include EventTarget
    include Node
    include Internal::ParentNode
    include Internal::ElementShadow
    include Internal::ElementTopLayer
    include Internal::ElementGeometry
    include Internal::ElementAria

    # Ruby block-style listener (in addition to the (type, callable,
    # options) form inherited from EventTarget). Returns the resolved
    # listener so callers can pass it back to remove_event_listener.
    def on(type, &block)
      add_event_listener(type, block)
      block
    end

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
      # WHATWG "string replace all". textContent is a nullable DOMString, so
      # null AND undefined both mean "no value" -> clear the children with no
      # replacement text. The children are detached one by one (rather than via
      # the backend's `content=`, which frees their whole subtree) so a
      # reference to a removed node keeps its own descendants intact.
      string_replace_all(value)
    end

    def inner_html
      if @__node__.name == "template"
        @document.template_content_inner_html(self)
      else
        @__node__.inner_html
      end
    end

    def inner_html=(value)
      if @__node__.name == "template"
        # `<template>` content is invisible to outer selectors in real DOM (it
        # lives in a separate DocumentFragment exposed via `[:content]`). HTML's
        # innerHTML setter retargets to that fragment and replaces all of ITS
        # children, so the record belongs there, not on the template element
        # (which has no children of its own to swap).
        @document.attach_template_content(self, value.to_s)
        return
      end

      removed = @__node__.children.to_a
      @__node__.inner_html = value.to_s
      @document.migrate_template_descendants(@__node__)
      mark_fragment_scripts_started(@__node__.children.to_a)
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

    HTML_NAMESPACE = Internal::Namespaces::HTML

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

    # The createElementNS metadata, but only when it says something wrapping the
    # backend node would not work out on its own — a namespace other than HTML,
    # or a prefix. nil otherwise, so a clone walk can skip the node.
    def __internal_namespace_metadata__
      return nil if @__ns_qname.nil?
      return nil if @__ns_uri == HTML_NAMESPACE && @__ns_prefix.nil?

      [@__ns_uri, @__ns_prefix, @__ns_local, @__ns_qname]
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

    SVG_NAMESPACE = Internal::Namespaces::SVG

    # Local names for which a reflected DOMTokenList IDL attribute is defined,
    # per namespace; elsewhere the attribute does not exist (→ undefined). `rel`
    # is reflected on the `a` of all three namespaces that define one.
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
      # "Replace" order: the old element goes first (step 10), then the insert
      # and its step 5 (step 12) run against the tree that leaves behind.
      @document.detach_node(@__node__)
      anchor = nil if anchor && anchor.parent != parent
      @document.__internal_ranges_will_insert__(parent, anchor, new_nodes.size)
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
      composed = Node.composed_option?(options)
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

      # step 3 looks for the attribute whose QUALIFIED name matches, so an
      # element carrying only `xml:b` counts as not having `b`. The backend's
      # `node.key?` answers by local name and would report it present.
      key = normalize_attr_key(name)
      present = !Backend.attr_value_by_qualified_name(@__node__, key).nil?
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

    # setAttributeNodeNS is defined as the very same steps as setAttributeNode
    # ("set an attribute"): the namespace is the Attr's own, so there is nothing
    # left for the NS form to do differently. The JS bridge already routed it
    # here; this is the Ruby caller's way in.
    def set_attribute_node_ns(attr)
      set_attribute_node(attr)
    end

    # removeAttributeNode step 1: "If this's attribute list does not contain
    # attr, throw a NotFoundError." What counts is the Attr itself, not its
    # name — one that belongs to another element, or to none, is not in this
    # list even when this element has an attribute of the same name.
    def remove_attribute_node(attr)
      owner = attr.owner_element if attr.respond_to?(:owner_element)
      unless owner.equal?(self)
        raise DOMException::NotFoundError,
          "the attribute #{attr.respond_to?(:name) ? attr.name.inspect : attr.inspect} is not this element's"
      end

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









    # The accessibility tree rooted at this element (a synthetic root whose
    # children are this element's accessible nodes). See
    # Internal::AccessibilityTree.
    def accessibility_tree
      Internal::AccessibilityTree.build(self)
    end
    alias_method :aria_tree, :accessibility_tree


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
        node = convert_for_insert([element], parent, @__node__).first
        @__node__.add_previous_sibling(node)
        notify_child_list(added: [node], target: parent)
      when "afterbegin"
        first = @__node__.children.first
        node = convert_for_insert([element], @__node__, first).first
        first = nil if first && first.parent != @__node__
        first ? first.add_previous_sibling(node) : @__node__.add_child(node)
        notify_child_list(added: [node])
      when "beforeend"
        node = convert_for_insert([element], @__node__, nil).first
        @__node__.add_child(node)
        notify_child_list(added: [node])
      when "afterend"
        parent = @__node__.parent
        return nil unless parent

        validate_adjacent_document_insert!(parent, element)
        node = convert_for_insert([element], parent, @__node__.next).first
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
        @document.__internal_ranges_will_insert__(parent, @__node__, nodes.size)
        nodes.each { |n| @__node__.add_previous_sibling(n) }
        notify_child_list(added: nodes, target: parent)
      when "afterbegin"
        first = @__node__.children.first
        @document.__internal_ranges_will_insert__(@__node__, first, nodes.size)
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
        @document.__internal_ranges_will_insert__(parent, @__node__.next, nodes.size)
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
    # WHATWG names this `replaceWith`; `replace_with_nodes` is the older Dommy
    # spelling, kept because callers use it.
    alias replace_with replace_with_nodes

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
      # HTML click(): "if this element is a form control that is disabled,
      # then return" — a disabled control fires no event at all, so a listener
      # bound to it never runs.
      return false if __internal_actually_disabled__

      # HTML click(): "if this element's click in progress flag is set, then
      # return". It is what stops a label from clicking itself to death: the
      # label's activation behavior clicks its labeled control, the control's
      # click bubbles back to the label, and the label forwards it again. A
      # <meter>, <output> or <progress> in a <label> did exactly that until the
      # stack ran out, because the "leave interactive content alone" guard in
      # the label does not cover a control that is not interactive content.
      return false if @__click_in_progress

      @__click_in_progress = true
      begin
        # Everything else (picking the activation target, the pre-activation
        # toggle, running or undoing the activation behavior) is dispatch's job,
        # so a synthesized `dispatchEvent(new MouseEvent("click"))` behaves
        # identically to click().
        dispatch_event(MouseEvent.new("click", "bubbles" => true, "cancelable" => true, "button" => 0))
      ensure
        # Not a method-level `ensure`: the early return above must not clear the
        # flag the click it returned from is still holding.
        @__click_in_progress = false
      end
    end

    # WHATWG "actually disabled". Only the disable-able form controls can be,
    # so the generic element never is; HTMLElement narrows it by local name.
    def __internal_actually_disabled__
      false
    end

    # HTML compiles an event handler content attribute lazily — the handler only
    # has to exist by the time an event of that type is dispatched at the
    # element. Doing it here, rather than only in the boot-time scan, is what
    # makes `onclick="…"` survive cloneNode / innerHTML: such an element never
    # went through that scan, so its handler would otherwise never fire.
    #
    # Each (element, type) is attempted once — a handler that fails to compile
    # is not retried on every dispatch.
    def __internal_wire_inline_handler__(type)
      return unless @document.inline_handler_wirer
      return if @__inline_wired&.key?(type)

      code = @__node__["on#{type}"]
      return if code.nil?

      (@__inline_wired ||= {})[type] = true
      @document.__internal_wire_inline_handlers__
    end

    # WHATWG "legacy-pre-activation behavior": run on the activation target
    # BEFORE the click is dispatched, so a listener already sees the new state
    # (a checkbox reads as checked inside its own onclick). Returns whatever
    # `legacy_canceled_activation_behavior` needs to undo it, or nil when the
    # element has none. The default element has none; HTMLInputElement overrides.
    def legacy_pre_activation_behavior
      nil
    end

    # Run when the click was canceled: undo the pre-activation change.
    def legacy_canceled_activation_behavior(_state); end

    # Activation behavior: the default action of a non-canceled click (a
    # hyperlink navigates; a submit button submits its form; a checkbox fires
    # input + change). The default element has none.
    def activation_behavior(_event); end

    # Whether this element has activation behavior, so dispatch can pick it as
    # the click's activation target. Default: no.
    def activation_target?
      false
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
        # Every interface HTML and SVG give relList to declares it with
        # reflect_token_list, so this arm is reached only for the one element
        # neither of them covers: <a> in the MathML namespace, which WPT's
        # dom/lists/DOMTokenList-coverage-for-attributes asserts has one. MathML
        # Core defines no <a> for it to belong to and Chromium answers undefined
        # (recorded in dommy-conformance's known-divergences), but a WPT
        # assertion outranks a browser here.
        return Bridge::ABSENT unless namespace_uri == Internal::Namespaces::MATHML && local_name == "a"

        (@reflected_token_lists ||= {})["rel"] ||= ClassList.new(self, "rel")
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
      when "translate"
        # `translate` is a boolean reflecting the element's translation mode,
        # which inherits: translate="yes"/"" → true, "no" → false, else the
        # nearest ancestor's mode; the root defaults to translate (true).
        translate_mode?
      when "hidden", "checked"
        # The two boolean-ish properties that are NOT reflections, and so are
        # not declared with reflect_boolean on the interfaces that have them:
        # `hidden` is a union type on every HTML element, and `checked` is the
        # element's checkedness rather than the `checked` attribute (which
        # `defaultChecked` reflects).
        return Bridge::ABSENT unless boolean_idl_attribute?(key)

        @__node__.key?(key)
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

      resolve_url(raw)
    end

    # Resolve a URL-valued attribute against the document base URL, falling back
    # to the raw value when it cannot be parsed. The result is a SERIALIZED URL,
    # so `a.href = "http://example.org/?ä"` reads back percent-encoded — which is
    # what the URL parser produces and what `URI.join` does not.
    def resolve_url(raw)
      base = @document.base_uri.to_s
      base = nil if base.empty?
      Internal::UrlParser.serialize(Internal::UrlParser.parse(raw.to_s, base))
    rescue Internal::UrlParser::Failure
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




    # The content attribute a plural ARIA element-references IDL attribute
    # reflects (`ariaDescribedByElements` → "aria-describedby",
    # `ariaLabelledByElements` → "aria-labelledby"), or nil. The IDL name is
    # `aria<Xxx>Elements`; the content attribute is "aria-" + <Xxx> lowercased.
    def aria_elements_attr(key)
      return nil unless key.is_a?(String) && key.start_with?("aria") && key.end_with?("Elements")
      return nil unless key.length > 12 && key[4] =~ /[A-Z]/

      "aria-#{key[4...-8].downcase}"
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

    # Which HTML elements these two are defined on. `hidden` is global (it lives
    # on HTMLElement); `checked` belongs to input alone, and an element that
    # answered it would be claiming an IDL attribute HTML never gave it — which
    # feature detection reads as a checkbox. The reflected booleans used to need
    # a table like this because they were answered here rather than by the
    # interfaces that declare them; they are reflect_boolean declarations now,
    # and the interface a declaration sits on IS the answer.
    BOOLEAN_IDL_OWNERS = {
      "checked" => %w[input].freeze
    }.freeze

    def boolean_idl_attribute?(key)
      owners = BOOLEAN_IDL_OWNERS[key]
      return true if owners.nil? # `hidden`, on every HTML element

      namespace_uri == HTML_NAMESPACE && owners.include?(local_name.to_s.downcase)
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
      when "hidden", "checked"
        # See the getter: the two that are not reflections. Funnel through
        # set_attribute / remove_attribute so MutationObserver attribute records
        # fire. On an element the IDL attribute does not belong to, the
        # assignment is an ordinary JS expando and must not touch the content
        # attribute.
        return Bridge::UNHANDLED unless boolean_idl_attribute?(key)

        name = key
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
      replaceChild cloneNode append prepend replaceChildren moveBefore before after getInnerHTML getHTML
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
      when "moveBefore"
        raise Bridge::TypeError, "moveBefore requires 2 arguments." if args.length < 2

        move_before(args[0], args[1])
        Bridge::UNDEFINED
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

    # WHATWG "get an attribute by name": the first attribute whose QUALIFIED
    # name matches, after the HTML lower-casing of step 1. The backend's
    # `node[name]` indexes by local name, so on an element carrying `xml:b` it
    # would answer a read of `b` with that attribute's value.
    def get_attribute(name)
      return nil if name.nil?

      Backend.attr_value_by_qualified_name(@__node__, normalize_attr_key(name))
    end

    def set_attribute(name, value)
      return nil if name.nil?

      # WHATWG: a qualifiedName not matching the Name production throws.
      # The WPT corpus exercises only the empty string here (other shapes
      # like "0"/":"/"invalid^Name" are deliberately treated as valid).
      raise DOMException::InvalidCharacterError, "empty attribute name" if name.to_s.empty?

      # step 2 (the HTML lower-casing) then step 4: the attribute is the one
      # whose QUALIFIED name matches. A plain `node[key] = v` write indexes by
      # local name, so it would land on a prefixed `xml:b` when asked for `b`;
      # and it goes through the HTML backend, which lower-cases the name a
      # case-sensitive element must keep. The namespace-aware write does neither.
      key = normalize_attr_key(name)
      existing = Backend.attr_by_qualified_name(@__node__, key)
      if existing
        # step 5: change the attribute that is already there, keeping its
        # namespace — this is one attribute, not a new null-namespace one.
        info = Backend.attribute_ns_info(existing)
        old = info[:value]
        Backend.set_attribute_ns(@__node__, info[:namespace_uri], info[:prefix],
                                 info[:local_name], info[:qualified_name], value.to_s)
        ns = info[:namespace_uri]
        recorded_name = ns ? info[:local_name] : key
      else
        # step 6-7: a new attribute whose local name is the qualified name.
        old = nil
        Backend.set_attribute_ns(@__node__, nil, nil, key, key, value.to_s)
        ns = nil
        recorded_name = key
      end
      # A direct write to an `aria-*` IDREF attribute drops any explicitly-set
      # element reference, so the IDL getter re-resolves the new IDREF.
      clear_aria_element_ref_for(key) if key.start_with?("aria-")
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: recorded_name,
                                          old_value: old, namespace: ns)
      nil
    end

    def has_attribute?(name)
      return false if name.nil?

      !Backend.attr_value_by_qualified_name(@__node__, normalize_attr_key(name)).nil?
    end

    def remove_attribute(name)
      return nil if name.nil?

      # "remove an attribute by name" matches on the QUALIFIED name, so resolve
      # the attribute node first and remove it by its own (namespace, localName).
      key = normalize_attr_key(name)
      removed = Backend.attr_by_qualified_name(@__node__, key)
      return nil if removed.nil?

      info = Backend.attribute_ns_info(removed)
      old = info[:value]
      # Detach the cached Attr (caching its value) *before* the backend drop, so a
      # held reference keeps the value it had when removed and reports
      # `ownerElement === null` (so it's no longer "in use").
      @attributes&.__internal_evict__(info[:namespace_uri], info[:local_name])
      Backend.remove_attribute_ns(@__node__, info[:namespace_uri], info[:local_name])
      # Removing an `aria-*` IDREF attribute also clears any explicitly-set
      # element reference (the IDL getter then returns null).
      clear_aria_element_ref_for(key) if key.start_with?("aria-")
      @document.notify_attribute_mutation(target_node: @__node__,
                                          attribute_name: info[:namespace_uri] ? info[:local_name] : key,
                                          old_value: old, namespace: info[:namespace_uri])
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
      Internal::WebIDL.node!(child)
      # WHATWG pre-insert validates the reference the CALLER gave (step 1), and
      # only then, in step 3, replaces it with the node's next sibling when it is
      # the node being inserted — so "insert x before x" doesn't move x. Doing
      # the swap first would accept `insertBefore(x, x)` for an x that is not a
      # child of this node, which step 3 of the validity check rejects.
      ensure_pre_insertion_validity!(child, reference)
      reference = wrapped_next_sibling(reference) if same_wrapped_node?(reference, child)
      ref_node =
        if reference.nil? || (defined?(Bridge::UNDEFINED) && reference.equal?(Bridge::UNDEFINED))
          nil
        else
          unwrap_dom_node(reference)
        end
      # Insert step 6's insertion point, measured BEFORE anything moves: the
      # reference child's previous sibling, or the parent's last child when
      # appending. For `parent.insertBefore(itsLastChild, null)` that is the
      # node being inserted, which a post-hoc look at the new tree cannot give.
      record_previous = insertion_previous_sibling(@__node__, ref_node)
      record_next = wrap_sibling(ref_node)
      nodes = convert_for_insert([child], @__node__, ref_node)
      ref_node = nil if ref_node && ref_node.parent != @__node__
      if ref_node.nil?
        append_dom_nodes(nodes)
      else
        # The reference is guaranteed (by validity) to be a child here. Insert in
        # order before it: each new node becomes its immediate previous sibling,
        # so forward iteration yields the original order (reverse would flip a
        # multi-node fragment).
        nodes.each { |node| ref_node.add_previous_sibling(node) }
      end

      notify_child_list(added: nodes, previous_sibling: record_previous,
                        next_sibling: record_next)
      child
    end

    def remove_child(child)
      Internal::WebIDL.node!(child)
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
      Internal::WebIDL.node!(new_child)
      Internal::WebIDL.node!(old_child)
      # replaceChild shares the pre-insertion checks (ancestor, node type,
      # doctype placement); the reference child here is old_child, so step 3
      # also enforces that it is actually a child (NotFoundError otherwise).
      ensure_pre_insertion_validity!(new_child, old_child)
      old_node = unwrap_dom_node(old_child)

      replace_child_within(new_child, old_node)
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
      clone =
        if @__ns_qname
          @document.wrap_cloned_element_ns(copy, @__ns_uri, @__ns_prefix, @__ns_local, @__ns_qname)
        else
          @document.wrap_node(copy)
        end
      # A deep clone copies the backend tree, but the createElementNS metadata
      # lives on the wrappers — so a descendant created in another namespace, or
      # in none, would come back from the clone reporting the HTML namespace.
      copy_namespaces_into(@__node__, copy) if deep_arg && @document.__internal_namespaced_elements__?
      # HTML cloning steps: propagate form-control dirty state (an input's value /
      # checkedness, …) that lives on the wrapper, not the backend node.
      @document.__internal_apply_cloning_steps__(@__node__, copy, deep_arg)
      clone
    end

    # Walk the original subtree and its copy in step, reapplying the namespace
    # metadata of every descendant that carries a non-default one. Only the
    # originals that already have a wrapper can be carrying it, so this never
    # builds a wrapper it does not need.
    def copy_namespaces_into(original, copy)
      copies = copy.children.to_a
      original.children.each_with_index do |orig_child, index|
        copy_child = copies[index]
        break if copy_child.nil?

        wrapper = @document.__internal_cached_wrapper__(orig_child)
        meta = wrapper.__internal_namespace_metadata__ if wrapper.respond_to?(:__internal_namespace_metadata__)
        @document.wrap_cloned_element_ns(copy_child, *meta) if meta
        copy_namespaces_into(orig_child, copy_child)
      end
      nil
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

    # WHATWG "get the parent": the node's parent, and nothing more — a detached
    # element has none, so an event dispatched on one stays inside the detached
    # subtree instead of reaching the document.
    def __internal_event_parent__
      wrap_parent(@__node__.parent)
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
      !(namespace_uri == Internal::Namespaces::HTML && @document.html_document?)
    end

    # Insertion / scroll / popover helpers.
    def append_dom_nodes(nodes)
      nodes.each { |node| @__node__.add_child(node) }
    end

    # `check_insertion!` / `check_hierarchy!` now live in Internal::ParentNode:
    # WHATWG applies the no-cycle rule to every element-like parent, so Fragment
    # and ShadowRoot need it too and Element has nothing left to override.

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
    #
    # This is the one place that unlinks a node WITHOUT the pre-removing steps,
    # deliberately: no DOM removal happened (the node was parentless before and
    # after), so running them would move live Range / NodeIterator positions for
    # a purely internal round trip.
    def matches_detached_node?(node, selector)
      Parser.fragment("", owner_doc: node.document).add_child(node)
      node.matches?(selector)
    ensure
      node.unlink
    end


  end
end
