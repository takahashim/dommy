# frozen_string_literal: true

require "uri"

require_relative "internal/node_wrapper_cache"
require_relative "internal/mutation_coordinator"
require_relative "internal/shadow_root_registry"
require_relative "internal/cookie_jar"
require_relative "internal/node_traversal"
require_relative "internal/observer_manager"
require_relative "internal/template_content_registry"

module Dommy
  # Stub DocumentType (`<!doctype html>`) — exposes `name` and `nodeType=10`.
  # Real browsers also expose `publicId` / `systemId` which we leave empty
  # since HTML5 doctypes don't carry those.
  class DocumentType
    include Node

    attr_reader :name

    def initialize(name)
      @name = name.to_s
    end

    def __js_get__(key)
      case key
      when "name"
        @name
      when "nodeType"
        10
      when "publicId"
        ""
      when "systemId"
        ""
      end
    end
  end

  # `document` — the entry point for DOM construction and querying.
  # Wrapper caching keeps DOM identity stable across repeated
  # traversals (`body.children[0].parentElement`).
  class Document
    include EventTarget
    include Node

    attr_reader :body, :nokogiri_doc
    attr_accessor :default_view
    # content_type defaults to "text/html"; settable so an integration layer
    # can reflect the response Content-Type. Read-only over the JS bridge.
    attr_accessor :content_type

    def initialize(host = nil, nokogiri_doc: nil, default_view: nil)
      @host = host
      @default_view = default_view
      @node_wrapper_cache = Internal::NodeWrapperCache.new(self)
      @observer_manager = Internal::ObserverManager.new
      @shadow_registry = Internal::ShadowRootRegistry.new
      @cookie_jar = Internal::CookieJar.new
      @template_content_registry = Internal::TemplateContentRegistry.new(self)
      @mutation_coordinator = Internal::MutationCoordinator.new(self, @observer_manager)
      @nokogiri_doc = nokogiri_doc || Backend.parse("<!doctype html><html><head></head><body></body></html>")
      body_node = @nokogiri_doc.at_css("body")
      @body = wrap_node(body_node) if body_node
      @content_type = "text/html"
    end

    # ----- Public Ruby API (snake_case) -----

    def title
      read_title
    end

    def title=(value)
      write_title(value.to_s)
    end

    def document_element
      wrap_node(@nokogiri_doc.at_css("html"))
    end

    def head
      wrap_node(@nokogiri_doc.at_css("head"))
    end

    # Serialize the whole document to HTML (including the doctype).
    def to_html
      @nokogiri_doc.to_html
    end

    # XPath queries returning wrapped nodes (Element / TextNode / etc).
    def at_xpath(expression)
      node = @nokogiri_doc.at_xpath(expression)
      node && wrap_node(node)
    end

    def xpath(expression)
      @nokogiri_doc.xpath(expression).map { |node| wrap_node(node) }
    end

    # `document.URL` / `documentURI` — both return location.href in
    # real browsers (legacy aliases of the same field).
    def url
      view = @default_view
      view&.location ? view.location.href : ""
    end

    alias document_uri url

    # `document.baseURI` — resolves the first `<base href>` (if any)
    # relative to the document URL; otherwise just the document URL.
    # When `<base href>` is itself absolute, that wins. Browsers also
    # ignore subsequent <base> elements; we mirror that.
    def base_uri
      doc_url = url
      base_el = @nokogiri_doc.at_css("base[href]")
      return doc_url unless base_el

      href = base_el["href"].to_s
      return doc_url if href.empty?

      begin
        URI.join(doc_url.to_s.empty? ? "about:blank" : doc_url, href).to_s
      rescue URI::InvalidURIError
        doc_url
      end
    end

    # `document.domain` — host portion of the URL. Real browsers
    # restrict cross-origin reads of this; we just return the bare host.
    def domain
      view = @default_view
      return "" unless view&.location

      view.location.__js_get__("hostname").to_s
    end

    # `document.origin` — serialized origin of the document URL, mirroring
    # `window.location.origin`. Empty when there is no associated window.
    def origin
      view = @default_view
      return "" unless view&.location

      view.location.__js_get__("origin").to_s
    end

    # `document.referrer` — Dommy never has a referring page, so this
    # is always empty.
    def referrer
      ""
    end

    # Live HTMLCollection helpers — each call re-queries the
    # document so post-mutation reads reflect the current state.
    def links
      HTMLCollection.new do
        @nokogiri_doc.css("a[href], area[href]").map { |n| wrap_node(n) }.compact
      end
    end

    def forms
      HTMLCollection.new do
        @nokogiri_doc.css("form").map { |n| wrap_node(n) }.compact
      end
    end

    def scripts
      HTMLCollection.new do
        @nokogiri_doc.css("script").map { |n| wrap_node(n) }.compact
      end
    end

    def images
      HTMLCollection.new do
        @nokogiri_doc.css("img").map { |n| wrap_node(n) }.compact
      end
    end

    # ParentNode mixin (operates on the document's element children —
    # in practice the `<html>` root).
    def children
      HTMLCollection.new do
        root = @nokogiri_doc.root
        root ? [wrap_node(root)].compact : []
      end
    end

    def child_element_count
      children.size
    end

    def first_element_child
      wrap_node(@nokogiri_doc.root)
    end

    def last_element_child
      wrap_node(@nokogiri_doc.root)
    end

    # Currently-focused element (or body if none). Updated via
    # `el.focus()` / `el.blur()`.
    def active_element
      @active_element || @body
    end

    def __internal_set_active_element__(el)
      @active_element = el
    end

    # Create a detached Attr. `setAttributeNode` attaches it to an
    # element. Per spec, name must match the XML Name production —
    # invalid names throw InvalidCharacterError.
    def create_attribute(name)
      @node_wrapper_cache.create_attribute(name)
    end

    def create_attribute_ns(namespace_uri, qualified_name)
      @node_wrapper_cache.create_attribute_ns(namespace_uri, qualified_name)
    end

    # `document.createTreeWalker(root, whatToShow?, filter?)` — stateful
    # tree traversal with sibling/parent navigation. `filter` may be a
    # Ruby Proc, a JS-bridge callable, or an object with
    # `accept_node` / `acceptNode`.
    def create_tree_walker(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      TreeWalker.new(root, what_to_show, filter)
    end

    # Copy a node from another document into this one. The returned
    # wrapper is owned by `this`. Per spec, the source node is left
    # in place. `deep: true` copies the entire subtree.
    def import_node(node, deep = false)
      return nil unless node.respond_to?(:__dommy_backend_node__)

      copy = clone_into_doc(node.__dommy_backend_node__, deep)
      wrap_node(copy)
    end

    # Move a node from another document into this one. The source
    # node is detached from its previous owner and its ownerDocument
    # becomes this. Returns the (possibly re-wrapped) node.
    def adopt_node(node)
      return nil unless node.respond_to?(:__dommy_backend_node__)

      src = node.__dommy_backend_node__
      src.unlink if src.parent

      # Same document: just return the wrapper after the detach above.
      return wrap_node(src) if src.document == @nokogiri_doc

      # Cross-document: Nokogiri reassigns `src.document` when src is
      # added under a node owned by another document. We transiently
      # attach to our root, then unlink so src ends up free-floating
      # but now belongs to @nokogiri_doc. The underlying Ruby object
      # identity is preserved.
      src_doc_wrapper = node.instance_variable_get(:@document)
      @nokogiri_doc.root.add_child(src)
      src.unlink

      # Move the caller's Dommy wrapper from the source document's
      # wrapper cache into ours, and re-point its @document. This
      # keeps `adopt_node(x).equal?(x)` true across documents.
      node.instance_variable_set(:@document, self)
      if src_doc_wrapper.respond_to?(:__internal_reset_wrapper__)
        src_doc_wrapper.__internal_reset_wrapper__(src)
      end
      @node_wrapper_cache.register(src, node)
      node
    end

    # Legacy `document.createEvent("EventName")` factory. Returns an
    # Event subclass instance whose init still has to be called
    # (`event.initEvent(type, bubbles, cancelable)`). Matches the
    # mapping happy-dom and linkedom use.
    def create_event(type_name)
      name = type_name.to_s
      case name
      when "Event", "Events", "HTMLEvents"
        Event.new("")
      when "CustomEvent"
        CustomEvent.new("")
      when "MouseEvent", "MouseEvents"
        MouseEvent.new("")
      when "KeyboardEvent", "KeyboardEvents"
        KeyboardEvent.new("")
      else
        Event.new("")
      end
    end

    # Stubs for layout / focus / selection / execCommand APIs that
    # don't apply to a layout-less DOM. They exist so callers don't
    # hit NoMethodError; semantics are documented as no-op.

    def has_focus?
      true
    end

    alias has_focus has_focus?

    def get_selection
      @__selection ||= Selection.new(self)
    end

    def create_range
      Range.new(self)
    end

    # Fullscreen API — no actual fullscreen mode, just track which
    # element claimed it. `element.requestFullscreen()` sets it; this
    # is the read side.
    attr_reader :fullscreen_element

    def __internal_set_fullscreen_element__(element)
      previous = @fullscreen_element
      @fullscreen_element = element
      return if previous == element

      dispatch_event(Event.new("fullscreenchange"))
    end

    def exit_fullscreen
      return PromiseValue.resolve(@default_view, nil) if @fullscreen_element.nil?

      @fullscreen_element = nil
      dispatch_event(Event.new("fullscreenchange"))
      PromiseValue.resolve(@default_view, nil)
    end

    alias exitFullscreen exit_fullscreen

    def element_from_point(_x, _y)
      nil
    end

    def query_command_supported(_command)
      false
    end

    # `document.createNodeIterator(root, whatToShow?, filter?)` —
    # flat depth-first iteration.
    def create_node_iterator(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      NodeIterator.new(root, what_to_show, filter)
    end

    # Minimal DocumentType — represents the `<!doctype html>` line.
    # Always present in HTML5 documents we parse, so we synthesize a
    # stub object whose only useful field is `name`. Tests just need
    # `nodeType == 10`.
    def doctype
      @doctype ||= DocumentType.new("html")
    end

    # Delegate to CookieJar

    def cookie
      @cookie_jar.to_cookie_string
    end

    def cookie=(value)
      @cookie_jar.set_cookie(value)
      nil
    end

    def create_element_ns(namespace_uri, qualified_name)
      @node_wrapper_cache.create_element_ns(namespace_uri, qualified_name)
    end

    def get_elements_by_tag_name(name)
      @node_wrapper_cache.get_elements_by_tag_name(name)
    end

    def get_elements_by_name(name)
      @node_wrapper_cache.get_elements_by_name(name)
    end

    # `document.write(html)` — legacy API. Appends parsed nodes to the
    # body. Real browsers only re-stream the DOM during initial parse;
    # this stub is enough for tests that fire write() during teardown.
    def write(*args)
      html = args.join
      fragment = Parser.fragment(html, owner_doc: @nokogiri_doc)
      removed = []
      added = fragment.children.to_a
      added.each { |node| @body.__dommy_backend_node__.add_child(node) }
      notify_child_list_mutation(target_node: @body.__dommy_backend_node__, added_nodes: added, removed_nodes: removed)
      nil
    end

    # No-ops — real browsers reset the DOM on `open()` and flush
    # pending writes on `close()`. We don't model the parse pipeline.
    def open
      nil
    end

    def close
      nil
    end

    def [](key)
      __js_get__(key.to_s)
    end

    def []=(key, value)
      __js_set__(key.to_s, value)
    end

    # Create a Comment node. Wraps the Nokogiri comment so it flows
    # through the same wrap_node identity machinery as Element / TextNode.
    def create_comment(text)
      @node_wrapper_cache.create_comment(text)
    end

    def create_document_fragment
      @node_wrapper_cache.create_document_fragment
    end

    def get_elements_by_class_name(name)
      @node_wrapper_cache.get_elements_by_class_name(name)
    end

    def __js_get__(key)
      case key
      when "body"
        @body
      when "head"
        head
      when "doctype"
        doctype
      when "defaultView"
        @default_view
      when "fullscreenElement"
        @fullscreen_element
      when "fullscreenEnabled"
        true
      when "scrollingElement"
        wrap_node(@nokogiri_doc.at_css("html"))
      when "documentElement"
        wrap_node(@nokogiri_doc.at_css("html"))
      when "title"
        read_title
      when "cookie"
        cookie
      when "nodeType"
        9
      when "activeElement"
        active_element
      when "URL", "documentURI"
        url
      when "baseURI"
        base_uri
      when "domain"
        domain
      when "origin"
        origin
      when "contentType"
        content_type
      when "referrer"
        referrer
      when "links"
        links
      when "forms"
        forms
      when "scripts"
        scripts
      when "images"
        images
      when "children"
        children
      when "childElementCount"
        child_element_count
      when "firstElementChild"
        first_element_child
      when "lastElementChild"
        last_element_child
      when "nodeName"
        "#document"
      else
        nil
      end
    end

    def __js_set__(key, value)
      case key
      when "title"
        write_title(value.to_s)
      when "cookie"
        self.cookie = value.to_s
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[
      exitFullscreen startViewTransition createElement createElementNS createTextNode
      createComment createDocumentFragment querySelector querySelectorAll getElementById
      getElementsByClassName getElementsByTagName getElementsByName createAttribute
      createAttributeNS createTreeWalker createNodeIterator createEvent importNode adoptNode
      hasFocus getSelection elementFromPoint queryCommandSupported addEventListener
      removeEventListener dispatchEvent write open close
    ].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, args)
      case method
      when "exitFullscreen"
        exit_fullscreen
      when "startViewTransition"
        # View Transitions API stub. Spec: invoke the callback
        # synchronously; return a ViewTransition with already-resolved
        # `finished` / `ready` / `updateCallbackDone` promises.
        callback = args[0]
        if callback.respond_to?(:__js_call__)
          callback.__js_call__("call", [])
        elsif callback.respond_to?(:call)
          callback.call
        end

        ViewTransition.new(@default_view)
      when "createElement"
        create_element(args[0])
      when "createElementNS"
        create_element_ns(args[0], args[1])
      when "createTextNode"
        create_text_node(args[0])
      when "createComment"
        create_comment(args[0])
      when "createDocumentFragment"
        create_document_fragment
      when "querySelector"
        query_selector(args[0])
      when "querySelectorAll"
        query_selector_all(args[0])
      when "getElementById"
        get_element_by_id(args[0])
      when "getElementsByClassName"
        get_elements_by_class_name(args[0])
      when "getElementsByTagName"
        get_elements_by_tag_name(args[0])
      when "getElementsByName"
        get_elements_by_name(args[0])
      when "createAttribute"
        create_attribute(args[0])
      when "createAttributeNS"
        create_attribute_ns(args[0], args[1])
      when "createTreeWalker"
        create_tree_walker(args[0], args[1] || NodeFilter::SHOW_ALL, args[2])
      when "createNodeIterator"
        create_node_iterator(args[0], args[1] || NodeFilter::SHOW_ALL, args[2])
      when "createEvent"
        create_event(args[0])
      when "importNode"
        import_node(args[0], args[1])
      when "adoptNode"
        adopt_node(args[0])
      when "hasFocus"
        has_focus?
      when "getSelection"
        get_selection
      when "elementFromPoint"
        element_from_point(args[0], args[1])
      when "queryCommandSupported"
        query_command_supported(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      when "write"
        write(*args)
      when "open"
        open
      when "close"
        close
      else
        nil
      end
    end

    def __internal_event_parent__
      @default_view
    end

    # Delegate node wrapping to NodeWrapperCache
    def wrap_node(node)
      @node_wrapper_cache.wrap(node)
    end

    # Clear the cached wrapper so the next `wrap_node` creates a new
    # one. Used by `customElements.define` to upgrade nodes that were
    # constructed before the registration landed.
    def __internal_reset_wrapper__(nokogiri_node)
      @node_wrapper_cache.reset_wrapper(nokogiri_node)
    end

    # ShadowRoot identity registry: map a Nokogiri DocumentFragment
    # (the shadow tree's backing node) to the wrapping ShadowRoot so
    # slot assignment and event composition can walk from any inner
    # node back to its shadow boundary.
    # Delegate to ShadowRootRegistry

    def __internal_register_shadow_fragment__(fragment_node, shadow_root)
      @shadow_registry.register(fragment_node, shadow_root)
    end

    def __internal_shadow_root_for_fragment__(fragment_node)
      @shadow_registry.find_for_fragment(fragment_node)
    end

    def __internal_shadow_root_containing__(node)
      @shadow_registry.find_enclosing(node)
    end

    # Lifecycle callback dispatchers. Errors raised inside user
    # callbacks are swallowed so a single buggy custom element can't
    # break the whole mutation pipeline.
    # Delegate to MutationCoordinator

    def __internal_notify_connected__(element)
      @mutation_coordinator.notify_connected(element)
    end

    def __internal_notify_disconnected__(element)
      @mutation_coordinator.notify_disconnected(element)
    end

    def __internal_notify_connected_subtree__(nk)
      @mutation_coordinator.notify_connected_subtree(nk)
    end

    def __internal_notify_disconnected_subtree__(nk)
      @mutation_coordinator.notify_disconnected_subtree(nk)
    end

    def __internal_notify_attribute_changed__(element, name, old_value, new_value)
      @mutation_coordinator.notify_attribute_changed(element, name, old_value, new_value)
    end

    def register_observer(observer)
      @mutation_coordinator.register_observer(observer)
    end

    def unregister_observer(observer)
      @mutation_coordinator.unregister_observer(observer)
    end

    def notify_child_list_mutation(
      target_node:,
      added_nodes:,
      removed_nodes:,
      previous_sibling: nil,
      next_sibling: nil
    )
      @mutation_coordinator.notify_child_list_mutation(
        target_node: target_node,
        added_nodes: added_nodes,
        removed_nodes: removed_nodes,
        previous_sibling: previous_sibling,
        next_sibling: next_sibling
      )
    end

    def notify_attribute_mutation(target_node:, attribute_name:, old_value:)
      @mutation_coordinator.notify_attribute_mutation(
        target_node: target_node,
        attribute_name: attribute_name,
        old_value: old_value
      )
    end

    def notify_character_data_mutation(target_node:, old_value:)
      @mutation_coordinator.notify_character_data_mutation(
        target_node: target_node,
        old_value: old_value
      )
    end

    # Spec-permitted name pattern (XML "Name" production restricted to
    # ASCII for practicality). Used by `createElement` and
    # `createAttribute` to validate the argument.
    NAME_RE = /\A[A-Za-z_][\w\-.:]*\z/.freeze

    # Delegate factory methods to NodeWrapperCache

    def create_element(name)
      @node_wrapper_cache.create_element(name)
    end

    def create_text_node(text)
      @node_wrapper_cache.create_text_node(text)
    end

    def query_selector(selector)
      @node_wrapper_cache.query_selector(selector)
    end

    def query_selector_all(selector)
      @node_wrapper_cache.query_selector_all(selector)
    end

    def get_element_by_id(id)
      @node_wrapper_cache.get_element_by_id(id)
    end

    # ----- template content helpers (called from Element) -----

    def attach_template_content(template_element, html)
      @template_content_registry.attach(template_element, html)
    end

    def template_content_fragment(template_element)
      @template_content_registry.fragment_for(template_element)
    end

    def template_content_inner_html(template_element)
      @template_content_registry.inner_html_of(template_element)
    end

    def migrate_template_descendants(root)
      @template_content_registry.migrate_descendants(root)
    end

    def has_template_content?(nokogiri_node)
      @template_content_registry.has_content?(nokogiri_node)
    end

    private

    # Build a Nokogiri copy of the given node inside our @nokogiri_doc.
    # `deep: true` recurses into children. Used by importNode and
    # adoptNode for cross-document transfer.
    def clone_into_doc(source, deep)
      copy = if source.element?
        new_el = Backend.create_element(source.name, @nokogiri_doc)
        source.attribute_nodes.each { |a| new_el[a.name] = a.value }
        new_el
      elsif source.text?
        Backend.create_text(source.content, @nokogiri_doc)
      elsif source.is_a?(Backend.comment_class)
        Backend.create_comment(source.content, @nokogiri_doc)
      else
        # Fallback: serialize + reparse via fragment for unusual types.
        fragment = Parser.fragment(source.to_html, owner_doc: @nokogiri_doc)
        fragment.children.first || Backend.create_text("", @nokogiri_doc)
      end

      if deep && source.respond_to?(:children)
        source.children.each do |child|
          copy.add_child(clone_into_doc(child, true))
        end
      end

      copy
    end

    def read_title
      head = @nokogiri_doc.at_css("head")
      title = head&.at_css("title")
      title ? title.text : ""
    end

    def write_title(value)
      head = @nokogiri_doc.at_css("head")
      return unless head

      title = head.at_css("title")
      unless title
        title = Backend.create_element("title", @nokogiri_doc)
        head.add_child(title)
      end

      title.children.each(&:unlink)
      title.add_child(Backend.create_text(value, @nokogiri_doc))
    end

  end

  # `ViewTransition` — return value of `document.startViewTransition()`.
  # All three Promises (`finished` / `ready` / `updateCallbackDone`)
  # resolve immediately since dommy has no actual paint phase.
  #
  # Spec: https://drafts.csswg.org/css-view-transitions/
  class ViewTransition
    def initialize(window)
      @finished = PromiseValue.resolve(window, nil)
      @ready = PromiseValue.resolve(window, nil)
      @update_callback_done = PromiseValue.resolve(window, nil)
    end

    attr_reader :finished, :ready

    def update_callback_done
      @update_callback_done
    end

    alias updateCallbackDone update_callback_done

    def skip_transition
      nil
    end

    alias skipTransition skip_transition

    def __js_get__(key)
      case key
      when "finished"
        @finished
      when "ready"
        @ready
      when "updateCallbackDone"
        @update_callback_done
      end
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[skipTransition].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, _args)
      case method
      when "skipTransition"
        skip_transition
      end
    end
  end
end
