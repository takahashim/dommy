# frozen_string_literal: true

module Dommy
  # `ShadowRoot` — a DocumentFragment-shaped subtree attached to a
  # host Element via `attachShadow`. Lives in its own Nokogiri
  # fragment that's invisible to the outer document's tree walks
  # (querySelector, getElementById, children, etc.), which is the
  # core "encapsulation" the spec promises.
  #
  # Tree manipulation works the same as a normal Element/Fragment;
  # the boundary is enforced only on outer queries and event
  # composition. CSS scoping (`:host` / `::slotted` / `::part`, and this
  # tree's `<style>` rules) is handled by the cascade — see
  # `internal/css/rule_index.rb` and css-cascade.md.
  class ShadowRoot
    include EventTarget
    include Node
    include Internal::ParentNode

    attr_reader :host, :mode, :delegates_focus, :slot_assignment, :document

    def __dommy_backend_node__ = @__node__

    def initialize(host, mode:, delegates_focus: false, slot_assignment: "named")
      @host = host
      @mode = mode.to_s
      @delegates_focus = !!delegates_focus
      @slot_assignment = slot_assignment.to_s
      @document = host.document
      @__node__ = Parser.fragment("", owner_doc: @document.backend_doc)
      @document.__internal_register_shadow_fragment__(@__node__, self)
    end

    # ---- Public Ruby API (ParentNode + DocumentFragment mixin) ----

    def inner_html
      @__node__.children.map(&:to_html).join
    end

    def inner_html=(html)
      fragment = Parser.fragment(html.to_s, owner_doc: @document.backend_doc)
      __internal_replace_all__(fragment.children.to_a)
      nil
    end

    def text_content
      @__node__.text
    end

    def text_content=(value)
      # A ShadowRoot is a DocumentFragment, so its textContent setter is the
      # same WHATWG "string replace all" as Element's and Fragment's: one
      # childList record for the whole swap, and an empty value leaves no
      # children rather than an empty Text node.
      string_replace_all(value)
    end

    def children
      @__node__.element_children.map { |n| @document.wrap_node(n) }.compact
    end

    def child_nodes
      @__node__.children.map { |n| @document.wrap_node(n) }.compact
    end

    def child_element_count
      @__node__.element_children.size
    end

    def first_child
      @document.wrap_node(@__node__.children.first)
    end

    def last_child
      @document.wrap_node(@__node__.children.last)
    end

    def first_element_child
      @document.wrap_node(@__node__.element_children.first)
    end

    def last_element_child
      @document.wrap_node(@__node__.element_children.last)
    end

    # Whether this shadow root participates in the document (its host is
    # connected). A disconnected shadow tree has no active element and no live
    # style sheets.
    def connected?
      @host.respond_to?(:is_connected?) && @host.is_connected?
    end

    # `shadowRoot.activeElement` — the focused element, retargeted to this shadow
    # tree: the document's focused element when it is inside this (connected)
    # shadow root, else null.
    def active_element
      return nil unless connected?

      focused = @document.__internal_focused_element__
      focused && contains?(focused) ? focused : nil
    end

    # `shadowRoot.styleSheets` — the CSSStyleSheets of the `<style>` / `<link>`
    # elements within this (connected) shadow tree (mirrors Document#style_sheets);
    # empty for a disconnected shadow root.
    def style_sheets
      return NodeList.new unless connected?

      sheets = query_selector_all("style, link").filter_map do |element|
        element.sheet if element.respond_to?(:sheet)
      end
      NodeList.new(sheets)
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

    # Node-level child mutations the spec exposes on a DocumentFragment (and so
    # on a ShadowRoot). lit-html drives rendering through `insertBefore` /
    # `removeChild` / `replaceChild` against the render root, so a shadow root
    # must support them — not just appendChild.
    def insert_before(node, ref)
      ensure_pre_insertion_validity!(node, ref)
      ref_bn = ref.respond_to?(:__dommy_backend_node__) ? ref.__dommy_backend_node__ : nil
      ref_bn = nil unless ref_bn && ref_bn.parent == @__node__
      ref_bn = reference_past_args(ref_bn, backend_nodes_in([node]))
      nodes = convert_for_insert([node], @__node__, ref_bn)
      ref_bn = nil if ref_bn && ref_bn.parent != @__node__
      if ref_bn
        nodes.each { |n| ref_bn.add_previous_sibling(n) }
      else
        nodes.each { |n| @__node__.add_child(n) }
      end
      notify_child_list(added: nodes)
      node
    end

    def remove_child(node)
      bn = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
      raise DOMException::NotFoundError, "node is not a child of this shadow root" unless bn && bn.parent == @__node__

      @document.detach_node(bn)
      notify_child_list(removed: [bn])
      node
    end

    def replace_child(new_child, old_child)
      # As for a DocumentFragment: the validity check (whose step 2 rejects a
      # cycle) precedes the reference child's parentage check.
      ensure_pre_insertion_validity!(new_child, old_child)
      old_bn = old_child.respond_to?(:__dommy_backend_node__) ? old_child.__dommy_backend_node__ : nil
      raise DOMException::NotFoundError, "node is not a child of this shadow root" unless old_bn && old_bn.parent == @__node__

      # The shared "replace a child within a parent" primitive — remove first,
      # then insert, exactly as for an Element or a DocumentFragment.
      replace_child_within(new_child, old_bn)
      old_child
    end

    # `getRootNode()` returns the ShadowRoot itself; `getRootNode({composed:
    # true})` crosses the shadow boundary and returns the root of the host's
    # tree (the document, or an outer shadow root for nested shadows).
    def get_root_node(options = nil)
      composed = options.is_a?(Hash) &&
        EventTarget.js_truthy?(options.key?("composed") ? options["composed"] : options[:composed])
      return self unless composed
      return @host.root_node({"composed" => true}) if @host.respond_to?(:root_node)

      self
    end

    def contains?(other)
      return false unless other.respond_to?(:__dommy_backend_node__)

      other_node = other.__dommy_backend_node__
      return true if other_node == @__node__

      Internal::NodeTraversal.ancestor_of?(@__node__, other_node)
    end

    # `[]` accessor mirrors the bracket convention used elsewhere.
    def [](key)
      __js_get__(key.to_s)
    end

    def []=(k, v)
      __js_set__(k.to_s, v)
    end

    def __js_get__(key)
      case key
      when "host"
        @host
      when "mode"
        @mode
      when "delegatesFocus"
        @delegates_focus
      when "slotAssignment"
        @slot_assignment
      when "activeElement"
        active_element
      when "styleSheets"
        style_sheets
      when "innerHTML"
        inner_html
      when "textContent"
        text_content
      when "children"
        children
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
      when "nodeType"
        11
      when "nodeName"
        "#document-fragment"
      else
        # Any unknown key (incl. framework-private `_`/`$` expandos like
        # lit-html's `_$litPart$`, which it probes with `=== undefined`) is
        # genuinely absent: JS `undefined`, `in` false — matching Element.
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "innerHTML"
        self.inner_html = value
      when "textContent"
        self.text_content = value
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[
      querySelector querySelectorAll getElementById append prepend replaceChildren appendChild
      insertBefore removeChild replaceChild
      getRootNode contains addEventListener removeEventListener dispatchEvent
      isEqualNode isSameNode hasChildNodes normalize compareDocumentPosition
    ]
    def __js_call__(method, args)
      case method
      when "querySelector"
        query_selector(Internal.css_query_arg!(args))
      when "querySelectorAll"
        query_selector_all(Internal.css_query_arg!(args))
      when "getElementById"
        get_element_by_id(args[0])
      when "isEqualNode"
        is_equal_node(args[0])
      when "isSameNode"
        is_same_node(args[0])
      when "compareDocumentPosition"
        compare_document_position(args[0])
      when "hasChildNodes"
        @__node__.children.any?
      when "normalize"
        nil
      when "append"
        append(*args)
      when "prepend"
        prepend(*args)
      when "replaceChildren"
        replace_children(*args)
      when "appendChild"
        append_child(args[0])
      when "insertBefore"
        insert_before(args[0], args[1])
      when "removeChild"
        remove_child(args[0])
      when "replaceChild"
        replace_child(args[0], args[1])
      when "getRootNode"
        get_root_node(args[0])
      when "contains"
        contains?(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    # Event bubbling stops at the ShadowRoot unless event has
    # `composed: true`. The host is the bubble-path successor when
    # composition crosses the boundary (handled in Event dispatch).
    def __internal_event_parent__
      nil
    end

  end
end
