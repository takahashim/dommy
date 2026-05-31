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
  # composition. CSS scoping (`:host`, `::slotted`) is out of scope.
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
      @__node__ = @document.nokogiri_doc.fragment("")
      @document.__internal_register_shadow_fragment__(@__node__, self)
    end

    # ---- Public Ruby API (ParentNode + DocumentFragment mixin) ----

    def inner_html
      @__node__.children.map(&:to_html).join
    end

    def inner_html=(html)
      removed = @__node__.children.to_a
      removed.each(&:unlink)
      fragment = Parser.fragment(html.to_s, owner_doc: @document.nokogiri_doc)
      added = fragment.children.to_a
      added.each { |n| @__node__.add_child(n) }
      notify_child_list(added: added, removed: removed)
      nil
    end

    def text_content
      @__node__.text
    end

    def text_content=(value)
      @__node__.children.each(&:unlink)
      @__node__.add_child(Backend.create_text(value.to_s, @document.nokogiri_doc))
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

    def query_selector(selector)
      return nil if selector.nil? || selector.to_s.empty?

      @document.wrap_node(@__node__.at_css(selector.to_s))
    end

    def query_selector_all(selector)
      return NodeList.new if selector.nil? || selector.to_s.empty?

      NodeList.new(@__node__.css(selector.to_s).map { |n| @document.wrap_node(n) }.compact)
    end

    def get_element_by_id(id)
      return nil if id.nil?

      @document.wrap_node(@__node__.at_css("##{id}"))
    end

    # `getRootNode()` returns the ShadowRoot itself (closed-shadow
    # semantics; `composed: true` callers go through the Event path).
    def get_root_node(_options = nil)
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
      getRootNode contains addEventListener removeEventListener dispatchEvent
    ]
    def __js_call__(method, args)
      case method
      when "querySelector"
        query_selector(Internal.css_query_arg!(args))
      when "querySelectorAll"
        query_selector_all(Internal.css_query_arg!(args))
      when "getElementById"
        get_element_by_id(args[0])
      when "append"
        append(*args)
      when "prepend"
        prepend(*args)
      when "replaceChildren"
        replace_children(*args)
      when "appendChild"
        append_child(args[0])
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
