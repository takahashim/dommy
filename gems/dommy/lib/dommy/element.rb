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

    # "adopt" sets the node document of the element's attributes along with
    # its own (DOM §4.5 step 3.3.1).
    def __internal_reseat__(backend_node, document)
      super
      @attributes&.__internal_adopt__(document)
      nil
    end

    def initialize(document, nokogiri_node)
      @document = document
      @__node__ = nokogiri_node
      @class_list = ClassList.new(self)
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

    # The fragment serializing algorithm: the HTML serialization in an HTML
    # document, the XML one anywhere else (the backend only HTML-serializes).
    def inner_html
      if !@document.html_document?
        Internal::XmlSerialization.serialize_children_of(self)
      elsif @__node__.name == "template"
        @document.template_content_inner_html(self)
      else
        @__node__.inner_html
      end
    end

    def inner_html=(value)
      unless @document.html_document?
        nodes = xml_fragment_nodes(value.to_s, self)
        mark_fragment_scripts_started(nodes)
        # A <template> is still the context, but the nodes replace its contents.
        (is_a?(HTMLTemplateElement) ? content : self).__internal_replace_all__(nodes)
        return
      end

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
    # started" flag set, so it never executes when inserted — and, like any
    # element the HTML parser inserts, its "force async" flag is cleared (HTML
    # §4.12.1.1), so an async-less one reports `.async === false` rather than
    # the "script this session created" default. Flag every script in the
    # freshly parsed backend subtree before the connection notification — which
    # is what would otherwise run them — fires.
    def mark_fragment_scripts_started(backend_nodes)
      backend_nodes.each do |nk|
        next unless nk.respond_to?(:element?) && nk.element?

        if nk.name == "script"
          wrapped = @document.wrap_node(nk)
          if wrapped.respond_to?(:__internal_mark_script_already_started__)
            wrapped.__internal_mark_script_already_started__
            wrapped.__internal_mark_parser_inserted__
          end
        end
        mark_fragment_scripts_started(nk.children.to_a) if nk.respond_to?(:children)
      end
    end

    HTML_NAMESPACE = Internal::Namespaces::HTML
    # More shadow trees nested in one another than any real page has.
    MAX_SHADOW_DEPTH = 100_000

    # tagName is the qualified name, ASCII-upper-cased only for an HTML-namespace
    # element whose node document is an HTML document. An XHTML element (HTML
    # namespace, but in an XML document) and any non-HTML-namespace element keep
    # their case.
    def tag_name
      qname = @__node__.name
      namespace_uri == HTML_NAMESPACE && @document.html_document? ? qname.upcase(:ascii) : qname
    end

    def element_prefix
      Backend.prefix(@__node__)
    end

    def id
      __internal_attribute_value__("id").to_s
    end

    def id=(value)
      __internal_set_attribute_value__("id", value.to_s)
    end

    def class_name
      __internal_attribute_value__("class").to_s
    end

    def class_name=(value)
      __internal_set_attribute_value__("class", value.to_s)
    end

    def class_list
      @class_list
    end

    SVG_NAMESPACE = Internal::Namespaces::SVG

    # `HTMLCollection` re-evaluates the child list on every
    # property access so callers that capture `el[:children]` once
    # see DOM mutations made between iterations — required by list
    # reconciliation patterns that rely on the spec's live
    # HTMLCollection semantics to detect already-positioned nodes.
    # Made on first read: most wrapped elements are never asked.
    def children
      @live_children ||= HTMLCollection.new(**Internal::ChildList.elements(-> { @__node__ }, -> { @document })) do
        @__node__.element_children.map { |n| @document.wrap_node(n) }.compact
      end
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

    # Live NodeList over this element's children (all node types, not just
    # elements), cached so `el.childNodes === el.childNodes` holds like the
    # spec's live NodeList. Made on first read, like #children.
    def live_child_nodes
      @live_child_nodes ||= LiveNodeList.new(**Internal::ChildList.nodes(-> { @__node__ }, -> { @document })) do
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

    # Outer HTML — serializes this element and its subtree (as XML outside an
    # HTML document, like #inner_html). Setter replaces this element in its
    # parent with the parsed fragment.
    def outer_html
      return Internal::XmlSerialization.serialize(self) unless @document.html_document?

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

      new_nodes = fragment_nodes(html.to_s, parent)
      anchor = @__node__.next_sibling
      removed = @__node__
      mark_fragment_scripts_started(new_nodes)
      # "Replace" order: the old element goes first (step 10), then the insert
      # and its step 5 (step 12) run against the tree that leaves behind.
      @document.detach_node(@__node__)
      anchor = nil if anchor && anchor.parent != parent
      @document.__internal_ranges_will_insert__(parent, anchor, new_nodes.size)
      if anchor
        new_nodes.each { |n| anchor.add_previous_sibling(n) }
      else
        new_nodes.each { |n| parent.add_child(n) }
      end

      notify_child_list(added: new_nodes, removed: [removed], target: parent)
    end

    # The fragment parsing algorithm with this element as its context, for
    # createContextualFragment: the backend nodes `markup` parses into, not
    # yet in any tree.
    def __internal_parse_fragment__(markup)
      fragment_nodes(markup, @__node__, html_as_body: true)
    end

    # The XML fragment parsing algorithm, for innerHTML / outerHTML outside an
    # HTML document. The parser is first fed a start tag declaring the default
    # namespace and the prefixes in scope on `context` (nil: the `body` in the
    # HTML namespace that stands in for a DocumentFragment parent), so the
    # markup resolves them as it would inside that element; the nodes are that
    # start tag's children, with each parsed <template>'s children moved into
    # its contents as the XML parser puts them. Markup that is not a
    # well-formed fragment, or that closes the start tag itself, is a
    # SyntaxError (DOM Parsing), not a backend error.
    def xml_fragment_nodes(markup, context)
      tag = xml_fragment_context_tag(context)
      top = Parser.fragment("<#{tag}>#{markup}</w>", owner_doc: @__node__.document).children.to_a
      unless top.size == 1 && top.first.element? && top.first.name == "w"
        raise DOMException::SyntaxError, "not a well-formed XML fragment"
      end

      nodes = top.first.children.to_a
      nodes.each { |node| @document.migrate_xml_template_descendants(node) }
      nodes
    rescue Backend.xml_syntax_error_class => e
      raise DOMException::SyntaxError, "not a well-formed XML fragment: #{e.message}"
    end

    # The context start tag's name and declarations: the default namespace
    # (xmlns="" when there is none, so the document's own default does not
    # leak in) and every prefix that still resolves on `context`.
    def xml_fragment_context_tag(context)
      return %(w xmlns="#{Internal::Namespaces::HTML}") unless context

      prefixes = []
      each_namespace_ancestor(context) do |el|
        prefixes << wrapper_prefix(el)
        el.attributes.each do |attr|
          next unless attr.namespace_uri == XMLNS_NAMESPACE
          next unless normalize_ns_prefix(attr.__js_get__("prefix")) == "xmlns"

          prefixes << attr.local_name
        end
      end
      tag = +%(w xmlns="#{xml_fragment_escape(context.lookup_namespace_uri(nil).to_s)}")
      (prefixes.compact.uniq - %w[xml xmlns]).each do |prefix|
        ns = context.lookup_namespace_uri(prefix)
        tag << %( xmlns:#{prefix}="#{xml_fragment_escape(ns)}") if ns
      end
      tag
    end

    def xml_fragment_escape(value)
      value.gsub("&", "&amp;").gsub("<", "&lt;").gsub('"', "&quot;")
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

      root = Internal::NodeTraversal.root_of(@__node__)
      return @document if root.is_a?(Backend.document_class)

      @document.wrap_node(root) || @document
    end

    alias get_root_node root_node

    # Merge adjacent text node siblings and drop empty text nodes.
    # WHATWG Node.normalize: drop empty Text nodes and merge each run of
    # contiguous Text nodes into the first, firing the matching mutation records
    # (childList for every removed node, characterData for the merged data).
    def toggle_attribute(name, force = nil)
      validate_attribute_name!(name)

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
      tokens = Internal::LiteralLookup.class_tokens(name)
      root = @__node__
      doc = @document
      HTMLCollection.new do
        next [] if tokens.empty?

        Internal::LiteralLookup.elements_with_classes(doc, root, tokens).map { |n| doc.wrap_node(n) }.compact
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

      # "remove an attribute": the attribute itself, by its namespace and
      # local name — another with the same qualified name may come first.
      remove_attribute_entry(attr.namespace_uri, attr.local_name)
      attr
    end

    # HTML namespace constants — most HTML elements live in xhtml ns.
    # The backend's: the HTML namespace for an HTML element, the parsed or
    # created namespace for any other — and null for an element in none
    # (`<r/>` from DOMParser, createElementNS(null, …)), not the HTML one.
    def namespace_uri
      Backend.namespace_uri(@__node__)
    end

    # The backend's local name is the DOM's: the HTML parser and createElement
    # already lower-case an HTML element's, a foreign, created or XML element
    # keeps its case (an SVG `fooBar` imported from another document is still
    # `fooBar`), and a prefixed element drops its prefix (`cp:coreProperties`
    # is `coreProperties`; its `name` is the qualified one).
    def local_name
      @__node__.local_name
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
      # From each tree's root to the host of its shadow root, if it is one.
      # Shadow trees do not nest in a cycle; the cap only keeps a malformed
      # chain from hanging.
      MAX_SHADOW_DEPTH.times do
        root = Internal::NodeTraversal.root_of(current)
        return true if root.is_a?(Backend.document_class)

        # Only a fragment can be a shadow root's.
        sr = root.document_fragment? && @document.__internal_shadow_root_for_fragment__(root)
        host = sr && sr.host
        return false unless host

        current = host.__dommy_backend_node__
      end
      false
    end

    alias connected? is_connected?






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

      # The context is the parent a sibling goes into, or this element; a
      # missing or Document parent throws before anything is parsed.
      context = %w[beforebegin afterend].include?(pos) ? insertion_parent! : @__node__
      nodes = fragment_nodes(html.to_s, context, html_as_body: true)
      mark_fragment_scripts_started(nodes)
      # `add_previous_sibling` inserts immediately before the anchor, so a forward
      # walk preserves document order; `add_next_sibling` inserts immediately
      # after, so afterend walks in reverse to keep order.
      case pos
      when "beforebegin"
        @document.__internal_ranges_will_insert__(context, @__node__, nodes.size)
        nodes.each { |n| @__node__.add_previous_sibling(n) }
        notify_child_list(added: nodes, target: context)
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
        @document.__internal_ranges_will_insert__(context, @__node__.next, nodes.size)
        nodes.reverse_each { |n| @__node__.add_next_sibling(n) }
        notify_child_list(added: nodes, target: context)
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

      code = __internal_attribute_value__("on#{type}")
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
      return nil if namespaced_unprefixed_attribute?

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
      when "scrollTop", "scrollLeft", "clientTop", "clientLeft"
        # Position-ish metrics: 0 (we never lay elements out in the page), as a
        # real browser reports for hidden / pre-paint elements.
        0
      when "clientWidth", "clientHeight", "scrollWidth", "scrollHeight"
        layout_size(key.end_with?("Width") ? :width : :height)
      when "children"
        children
      when "childNodes"
        live_child_nodes
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
      when "parentElement"
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
      when "className"
        # DOM reflects the `class` attribute as the `className` string
        # property (space-separated tokens, "" when absent).
        class_name
      when "id"
        id
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
      raw = __internal_attribute_value__("href")
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
      # HTML "encoding-parses" a URL-valued attribute: the document's character
      # encoding goes to the URL parser (it decides how the query is encoded).
      Internal::UrlParser.serialize(
        Internal::UrlParser.parse(raw.to_s, base, encoding: @document.character_encoding)
      )
    rescue Internal::UrlParser::Failure
      raw.to_s
    end

    # The content attribute an ARIA element-reference IDL attribute reflects
    # (`ariaActiveDescendantElement` → "aria-activedescendant"), or nil.
    def aria_element_attr(key) = Internal::ElementAria::ELEMENT_ATTRIBUTES[key]

    # The content attribute a plural ARIA element-references IDL attribute
    # reflects (`ariaLabelledByElements` → "aria-labelledby"), or nil.
    def aria_elements_attr(key) = Internal::ElementAria::ELEMENTS_ATTRIBUTES[key]

    # Drop any explicit ARIA element reference (singular or plural) whose content
    # attribute was just set directly (so the IDL getter re-resolves the IDREF).
    def clear_aria_element_ref_for(content_attr)
      @aria_element_refs&.delete_if { |key, _| aria_element_attr(key) == content_attr }
      @aria_elements_refs&.delete_if { |key, _| aria_elements_attr(key) == content_attr }
    end

    # The content attribute a role/ARIA string IDL attribute reflects
    # (`ariaAutoComplete` → "aria-autocomplete"), or nil for any other key.
    def aria_content_attr(key) = Internal::ElementAria::STRING_ATTRIBUTES[key]

    # Read a reflected nullable DOMString: the content attribute value, or nil
    # (→ JS null) when the attribute is absent.
    def aria_get(content_attr)
      __internal_attribute_value__(content_attr)
    end

    # Write a reflected nullable DOMString: null / undefined removes the content
    # attribute; any other value is ToString-coerced and set.
    def aria_set(content_attr, value)
      if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
        remove_attribute_ns(nil, content_attr)
      else
        __internal_set_attribute_value__(content_attr, value.to_s)
      end
      nil
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
      when "className"
        self.class_name = value
      when "classList"
        # WHATWG [PutForwards=value]: `el.classList = x` forwards to
        # `el.classList.value = x` (set the class attribute). Handling it here
        # (instead of letting the write fall through as unhandled) stops the JS
        # bridge from stashing a string expando that would shadow the classList
        # getter for the rest of the element's life.
        self.class_name = value
      when "id"
        self.id = value
      when "slot"
        self.slot = value
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
      toString getAttributeNode setAttributeNode removeAttributeNode attachShadow
      addEventListener removeEventListener dispatchEvent appendChild insertBefore removeChild
      replaceChild cloneNode append prepend replaceChildren moveBefore before after getInnerHTML getHTML
      remove replaceWith getBoundingClientRect getClientRects scrollIntoView scroll
      scrollTo scrollBy requestFullscreen isEqualNode
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
      when "getBoundingClientRect"
        get_bounding_client_rect
      when "getClientRects"
        get_client_rects
      when "scrollIntoView", "scroll", "scrollTo", "scrollBy"
        record_scroll(method, args)
      when "requestFullscreen"
        request_fullscreen
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

      # step 1: a qualifiedName that is not a valid attribute local name throws
      # ("0", ":" and "invalid^Name" are valid; "", "a b", "a=b" are not).
      validate_attribute_name!(name)

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
      attribute_change_steps(key, ns)
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: recorded_name,
                                          old_value: old, namespace: ns)
      nil
    end

    # HTML reads and writes a content attribute in no namespace — every
    # reflected IDL attribute, `id`, `class` and the algorithms that consult
    # one — where get_attribute / set_attribute take the first attribute
    # with the qualified name, whichever namespace it is in. DOM "get an
    # attribute value" and "set an attribute value" with a null namespace.
    def __internal_attribute_value__(local_name)
      Backend.no_namespace_attribute_value(@__node__, local_name)
    end

    # HTML's cloning steps, for the state an element keeps beside its
    # attributes: what a copy takes over, as a Hash, or nil when there is
    # nothing. Each interface and mixin with such state adds its own to what
    # `super` gives (#merge_cloning_state) and takes its own back, so the
    # steps run together as HTML's do — a script's "already started" and
    # its nonce, say.
    def __internal_cloning_state__ = nil

    def __internal_apply_cloning_state__(_state) = nil

    def __internal_has_attribute__?(local_name)
      !Backend.no_namespace_attribute_value(@__node__, local_name).nil?
    end

    def __internal_set_attribute_value__(local_name, value)
      old = Backend.no_namespace_attribute_value(@__node__, local_name)
      Backend.set_attribute_ns(@__node__, nil, nil, local_name, local_name, value.to_s)
      attribute_change_steps(local_name, nil)
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: local_name,
                                          old_value: old, namespace: nil)
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
      removed = Backend.attr_by_qualified_name(@__node__, normalize_attr_key(name))
      return nil if removed.nil?

      info = Backend.attribute_ns_info(removed)
      remove_attribute_entry(info[:namespace_uri], info[:local_name], info[:value])
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
      attribute_change_steps(local, ns)
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: local, old_value: old, namespace: ns)
      nil
    end

    def remove_attribute_ns(namespace, local_name)
      return nil if local_name.nil?

      remove_attribute_entry(namespace_arg(namespace), local_name.to_s)
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
      clone = @document.wrap_node(copy)
      # HTML cloning steps: propagate form-control dirty state (an input's value /
      # checkedness, …) that lives on the wrapper, not the backend node.
      @document.__internal_apply_cloning_steps__(@__node__, copy, deep_arg)
      clone
    end

    # ---- Internal helpers (single private section) ----
    private

    # `state`, what `super`'s cloning steps gave, with `own` added; nil while
    # both are empty.
    def merge_cloning_state(state, own)
      own.empty? ? state : (state || {}).merge(own)
    end

    # A layout size, `:width` or `:height`: 0, as an element nothing lays out
    # measures, or a best-effort estimate when the window opts into
    # approximate geometry (see #get_bounding_client_rect).
    def layout_size(dimension) = approximate_layout? ? __internal_approx_box[dimension] : 0

    # The attribute change steps for the state an element keeps beside its
    # attributes, run whenever the attribute with local name `local_name`
    # in `namespace` is set, changed or removed. Only attributes in no
    # namespace have such state: an `aria-*` element reference drops the
    # element set through its IDL attribute, so the IDREF is read again,
    # and `nonce` the nonce set through its IDL attribute, so the new value
    # is the element's nonce.
    def attribute_change_steps(local_name, namespace)
      return unless namespace.nil?

      clear_aria_element_ref_for(local_name) if local_name.start_with?("aria-")
      @cryptographic_nonce = nil if local_name == "nonce"
    end

    # DOM "remove an attribute": the attribute with namespace `ns` and local
    # name `local`, if the element has one, whose value is `old`. The cached
    # Attr is detached (caching its value) *before* the backend drop, so a
    # held reference keeps the value it had when removed and reports
    # `ownerElement === null` (so it's no longer "in use").
    # Spec: https://dom.spec.whatwg.org/#concept-element-attributes-remove
    def remove_attribute_entry(ns, local, old = Backend.get_attribute_ns(@__node__, ns, local))
      return if old.nil?

      @attributes&.__internal_evict__(ns, local)
      Backend.remove_attribute_ns(@__node__, ns, local)
      attribute_change_steps(local, ns)
      @document.notify_attribute_mutation(target_node: @__node__, attribute_name: local, old_value: old, namespace: ns)
    end

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
      %w[input button select textarea].include?(local_name) && __internal_has_attribute__?("disabled")
    end

    def attribute_signature
      Backend.attribute_nodes(@__node__).map { |a| [a.name, a.value] }.sort
    end

    # on* event-handler property helpers.
    # Attribute-key / child-wrapping / event-parent helpers.

    # setAttribute / toggleAttribute step 1: the DOM's "valid attribute local
    # name" (non-empty; no ASCII whitespace, NULL, "/", "=" or ">").
    def validate_attribute_name!(name)
      return if Internal::Namespaces.valid_attribute_local_name?(name.to_s)

      raise DOMException::InvalidCharacterError, "invalid attribute name: #{name.to_s.inspect}"
    end

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

    # Whether a backend node is an element in the HTML namespace — for the
    # children a table, a section or a row counts, which skip a same-named
    # element in another namespace (SVG's <caption>).
    def html_element_node?(node) = node.element? && Backend.namespace_uri(node) == HTML_NAMESPACE

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

    # The fragment parsing algorithm (DOM Parsing): the HTML one in an HTML
    # document, the XML one anywhere else, inside `context` (a backend node).
    # A context that is no element — a DocumentFragment or a shadow root —
    # parses as a `body` would, which is each parser's default; any other
    # element lends its tag and namespace, so markup inside an `<svg>` is SVG
    # and markup inside an `html` builds its head and body. With
    # `html_as_body`, an HTML document's `html` element parses as a `body`
    # too — what insertAdjacentHTML and createContextualFragment ask, and
    # outerHTML does not.
    def fragment_nodes(markup, context, html_as_body: false)
      context = nil unless context.element?
      if @document.html_document?
        context = nil if html_as_body && context && context.local_name == "html" && Backend.namespace_uri(context) == HTML_NAMESPACE
        Parser.fragment(markup, owner_doc: @__node__.document, context: context).children.to_a
      else
        xml_fragment_nodes(markup, context && @document.wrap_node(context))
      end
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

    # Whether one of the attributes is in a namespace with no prefix, so
    # that its qualified name is a plain one (`id`) the JS side's snapshot
    # would also answer `el.id` with — it reads no namespace there. Only
    # setAttributeNS makes such an attribute, so until one is made anywhere
    # (Backend.namespaced_unprefixed_attribute?) no element is asked.
    def namespaced_unprefixed_attribute?
      return false unless Backend.namespaced_unprefixed_attribute?

      Backend.attribute_nodes(@__node__).any? do |a|
        info = Backend.attribute_ns_info(a)
        info[:namespace_uri] && info[:prefix].nil?
      end
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
