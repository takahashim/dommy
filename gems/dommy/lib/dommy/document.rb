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
  # DocumentType (`<!doctype html>`) — exposes name / publicId / systemId and
  # nodeType=10. HTML5 doctypes carry empty public/system IDs, but
  # `implementation.createDocumentType` can set them.
  #
  # Two modes:
  #  * node-backed — wraps the Makiri DocumentType node of a parsed document
  #    (`document.doctype`). Participates in the tree machinery
  #    (compareDocumentPosition / getRootNode / sibling links) like any other
  #    backend-backed node, via the shared Node mixin.
  #  * synthetic — a standalone doctype (`implementation.createDocumentType`)
  #    carrying just name/public/system id and an owner document. No backend node,
  #    so it stays tree-DISCONNECTED per its detached nature.
  class DocumentType
    include Node

    # Mixed into a node-backed doctype only, so a synthetic one does NOT respond
    # to `__dommy_backend_node__` — leaving the Node mixin's guards (which key off
    # `respond_to?(:__dommy_backend_node__)`) to treat it as disconnected.
    module NodeBacked
      def __dommy_backend_node__ = @__node__
    end

    # `owner_document:` links a synthetic doctype to its document so the ChildNode
    # methods can act on the tree; a standalone one has none, so those methods are
    # no-ops per spec. `backend_node:` + `document:` build the node-backed variant
    # (a parsed-tree doctype or the createDocumentType factory node), which reads
    # name/publicId/systemId straight off the node (the factory preserves case).
    def initialize(name = "", public_id = "", system_id = "", owner_document: nil, backend_node: nil, document: nil)
      @__node__ = backend_node
      if backend_node
        @document = document
        @owner_document = document
        extend(NodeBacked)
      else
        @name = name.to_s
        @public_id = public_id.to_s
        @system_id = system_id.to_s
        @owner_document = owner_document
      end
    end

    def name
      @__node__ ? @__node__.name : @name
    end

    # Makiri reports nil for an absent public/system id; DOM exposes "".
    def public_id
      @__node__ ? @__node__.public_id.to_s : @public_id
    end

    def system_id
      @__node__ ? @__node__.system_id.to_s : @system_id
    end

    def parent_node
      # wrap_node maps the backend document node (the doctype's parent) to the
      # Dommy Document.
      @__node__ && @__node__.parent && @document.wrap_node(@__node__.parent)
    end

    def next_sibling
      @__node__ && @__node__.next && @document.wrap_node(@__node__.next)
    end

    def previous_sibling
      @__node__ && @__node__.previous && @document.wrap_node(@__node__.previous)
    end

    # ChildNode mixin — the doctype's parent is the document.
    def remove
      @owner_document&.__internal_remove_doctype__(self)
      nil
    end

    def before(*nodes)
      return nil unless @owner_document

      @owner_document.__internal_insert_at_doctype__(nodes, after: false)
      nil
    end

    def after(*nodes)
      return nil unless @owner_document

      @owner_document.__internal_insert_at_doctype__(nodes, after: true)
      nil
    end

    def replace_with(*nodes)
      return nil unless @owner_document

      @owner_document.__internal_insert_at_doctype__(nodes, after: false)
      remove
      nil
    end

    def __js_get__(key)
      case key
      when "name"
        name
      when "nodeName"
        # WHATWG: a DocumentType's nodeName is its name.
        name
      when "nodeType"
        10
      when "publicId"
        public_id
      when "systemId"
        system_id
      when "ownerDocument"
        @owner_document
      when "parentNode"
        parent_node
      when "parentElement"
        nil
      when "nextSibling"
        next_sibling
      when "previousSibling"
        previous_sibling
      when "childNodes"
        NodeList.new
      when "firstChild", "lastChild"
        nil
      end
    end

    include EventTarget

    def __internal_event_parent__
      parent_node
    end

    # Node.cloneNode on a doctype: a detached copy with the same name/publicId/
    # systemId (a doctype is a leaf, so `deep` is irrelevant). Node-backed when a
    # backend factory is available, else synthetic — either reports the same
    # values and isEqualNode-matches the original.
    def clone_node(_deep = false)
      if @__node__ && @document
        node = begin
          Backend.create_document_type(name, public_id, system_id, @document.backend_doc)
        rescue StandardError
          nil
        end
        return DocumentType.new(backend_node: node, document: @document) if node
      end
      DocumentType.new(name, public_id, system_id, owner_document: @owner_document)
    end

    include Bridge::Methods
    js_methods %w[isEqualNode isSameNode getRootNode hasChildNodes normalize compareDocumentPosition contains
      cloneNode appendChild insertBefore removeChild replaceChild before after replaceWith remove
      addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "cloneNode"
        clone_node(args[0])
      when "hasChildNodes"
        false
      when "contains"
        # A DocumentType is a leaf node: it contains only itself.
        !args[0].nil? && is_same_node(args[0])
      when "isEqualNode"
        is_equal_node(args[0])
      when "isSameNode"
        is_same_node(args[0])
      when "getRootNode"
        get_root_node(args[0])
      when "compareDocumentPosition"
        compare_document_position(args[0])
      when "appendChild", "insertBefore"
        raise Bridge::TypeError, "Argument is not a Node." unless args[0].is_a?(Dommy::Node)

        raise DOMException::HierarchyRequestError, "a DocumentType may not have children"
      when "removeChild", "replaceChild"
        raise Bridge::TypeError, "Argument is not a Node." unless args[0].is_a?(Dommy::Node)

        raise DOMException::NotFoundError, "the node to be removed is not a child of this node"
      when "before"
        before(*args)
      when "after"
        after(*args)
      when "replaceWith"
        replace_with(*args)
      when "remove"
        remove
      when "normalize"
        nil
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end
  end

  # `document.implementation` — the DOMImplementation.
  class DOMImplementation
    def initialize(document)
      @document = document
    end

    # A created DocumentType's node document is the implementation's document. When
    # the backend ships a doctype factory (the HTML backend) and accepts the name,
    # the result is a real, node-backed (but detached) DocumentType that can join
    # the tree; otherwise it falls back to a synthetic one. (Qualified-name QName
    # validation isn't enforced — createDocumentType is permissive, so the factory's
    # stricter name check is bypassed via the synthetic fallback rather than
    # raising; a couple of invalid-name WPT cases stay documented gaps.)
    def create_document_type(qualified_name, public_id, system_id)
      qn = qualified_name.to_s
      pub = public_id.to_s
      sys = system_id.to_s
      node =
        begin
          Backend.create_document_type(qn, pub, sys, @document.backend_doc)
        rescue ArgumentError
          nil
        end
      node ? DocumentType.new(backend_node: node, document: @document) : DocumentType.new(qn, pub, sys, owner_document: @document)
    end

    # `hasFeature()` is a no-op that always returns true (DOM Standard).
    def has_feature(*)
      true
    end

    # createDocument(namespace, qualifiedName, doctype?) — a fresh XML document
    # with, in tree order, the doctype (when given) then a document element
    # (namespace, qualifiedName) when qualifiedName is non-empty.
    def create_document(namespace, qualified_name, doctype = nil)
      doc = Document.new(nil, backend_doc: Backend.empty_xml_document)
      # createDocument's content type is keyed off the namespace. None is
      # "text/html", so tagName keeps its case; xhtml+xml still routes
      # createElement to the HTML namespace (so an XHTML document isEqualNode
      # an HTML one).
      doc.content_type =
        case namespace.to_s
        when Internal::Namespaces::HTML then "application/xhtml+xml"
        when Internal::Namespaces::SVG then "image/svg+xml"
        else "application/xml"
        end
      qn = qualified_name.to_s
      unless qn.empty?
        el = doc.send(:create_element_ns, namespace, qualified_name)
        Backend.set_document_root(doc.backend_doc, el.__dommy_backend_node__)
      end
      adopt_doctype_into(doc, doctype)
      doc
    end

    private

    # Place `doctype` (a DocumentType passed to createDocument) as `doc`'s first
    # child. Makiri can't move a node between documents, so — like adoption — the
    # doctype is re-created in `doc`'s backend from its name/publicId/systemId.
    # No-op for nil/undefined, a non-DocumentType, a backend without an XML doctype
    # factory, or a public/system id the backend rejects (createDocument itself
    # doesn't validate those — only XML *serialization* would — so a rejection just
    # leaves the doctype unplaced rather than throwing).
    def adopt_doctype_into(doc, doctype)
      return if doctype.nil? || doctype.equal?(Bridge::UNDEFINED)
      return unless doctype.is_a?(DocumentType)

      node =
        begin
          Backend.create_document_type(doctype.name, doctype.public_id, doctype.system_id, doc.backend_doc)
        rescue StandardError
          nil
        end
      return unless node

      root = doc.backend_doc.root
      root ? root.add_previous_sibling(node) : doc.backend_doc.add_child(node)
    end

    public

    # createHTMLDocument(title?) — a fresh HTML document (doctype + html > head,
    # body), with an optional <title>.
    def create_html_document(title = nil)
      doc = Document.new(nil, backend_doc: Backend.parse("<!DOCTYPE html><html><head></head><body></body></html>"))
      doc.title = title.to_s unless title.nil? || title.equal?(Bridge::UNDEFINED)
      doc
    end

    def __js_get__(_key) = Bridge::ABSENT # method-only; any property read is absent

    include Bridge::Methods
    js_methods %w[createDocumentType createDocument createHTMLDocument hasFeature]
    def __js_call__(method, args)
      case method
      when "createDocumentType"
        create_document_type(args[0], args[1], args[2])
      when "createDocument"
        create_document(args[0], args[1], args[2])
      when "createHTMLDocument"
        create_html_document(args[0])
      when "hasFeature"
        has_feature
      end
    end
  end

  # `document` — the entry point for DOM construction and querying.
  # Wrapper caching keeps DOM identity stable across repeated
  # traversals (`body.children[0].parentElement`).
  class Document
    include EventTarget
    include Node

    attr_reader :backend_doc
    attr_accessor :default_view
    # --- CSS cascade support (Internal::CSS) ---
    # Monotonic counter bumped on every DOM mutation; the CSS layer
    # invalidates its per-document style cache wholesale when it moves.
    # The cache slot itself is owned by Internal::CSS::Cascade.
    attr_accessor :__css_style_cache__

    def style_generation
      @style_generation || 0
    end

    def __internal_bump_style_generation__
      @style_generation = style_generation + 1
      nil
    end

    # A by-id/class/tag index of the backend element tree, memoized per DOM
    # generation, for SelectorMatcher's document-scoped fast path (or nil to tell
    # the caller to walk). Rebuilt lazily only after a mutation bumps
    # style_generation, so it costs one tree walk per generation and pays off when
    # several queries run before the next mutation.
    #
    # Adaptive bypass: if the index keeps getting invalidated after serving only a
    # handful of queries (a mutation-between-every-query workload, where building
    # it never pays back), stop building it and just walk — re-testing
    # periodically. This keeps the worst case at walk speed rather than the ~15%
    # regression an always-on index would add.
    SELECTOR_INDEX_MIN_REUSE = 3   # queries an index must serve to have paid for its build
    SELECTOR_INDEX_LOW_RUN_LIMIT = 8 # consecutive low-reuse generations before bypassing
    SELECTOR_INDEX_RETEST_GAP = 64 # generations to wait before re-testing a bypass

    def __internal_selector_index__
      gen = style_generation
      if @__sel_idx_gen != gen
        if @__sel_idx
          if @__sel_idx_served.to_i < SELECTOR_INDEX_MIN_REUSE
            @__sel_idx_low = @__sel_idx_low.to_i + 1
            @__sel_idx_bypass = true if @__sel_idx_low >= SELECTOR_INDEX_LOW_RUN_LIMIT
          else
            @__sel_idx_low = 0
          end
        end
        if @__sel_idx_bypass && (@__sel_idx_retest = @__sel_idx_retest.to_i + 1) >= SELECTOR_INDEX_RETEST_GAP
          @__sel_idx_bypass = false
          @__sel_idx_low = 0
          @__sel_idx_retest = 0
        end
        @__sel_idx = nil
        @__sel_idx_served = 0
        @__sel_idx_gen = gen
      end
      return nil if @__sel_idx_bypass

      @__sel_idx ||= Internal::SelectorIndex.build(@backend_doc)
      @__sel_idx_served += 1
      @__sel_idx
    end

    # An element-scoped querySelector(All) result cache (the document-rooted one
    # lives in NodeWrapperCache). jQuery `$(el).find(sel)` re-queries the same
    # (element, selector) constantly between mutations; this memoizes the match
    # set, keyed by [scope object_id, kind, selector] and tagged with the DOM
    # generation, so a hit skips the whole combinator match. Capped, and a
    # mutation (style_generation bump) makes every entry stale at once.
    SCOPED_QUERY_CACHE_CAP = 4096

    def __internal_scoped_query_get(key)
      entry = (@__scoped_query_cache ||= {})[key]
      entry && entry[0] == style_generation ? entry[1] : nil
    end

    def __internal_scoped_query_set(key, value)
      cache = (@__scoped_query_cache ||= {})
      cache.clear if cache.size >= SCOPED_QUERY_CACHE_CAP
      cache[key] = [style_generation, value]
      value
    end

    # A host-supplied `->(url) { css_text_or_nil }` resolving @import URLs to
    # CSS (Dommy has no network of its own — same idea as <link> filling).
    # Setting it invalidates cached styles so the next cascade picks up imports.
    attr_reader :css_import_resolver

    def css_import_resolver=(resolver)
      @css_import_resolver = resolver
      __internal_bump_style_generation__
    end
    # content_type defaults to "text/html"; settable so an integration layer
    # can reflect the response Content-Type. Read-only over the JS bridge.
    attr_accessor :content_type
    # A `->(source_text) {}` set by the JS layer to execute a classic <script>'s
    # body when it's connected (Dommy has no JS engine of its own). nil = inert
    # scripts (the default for a standalone DOM).
    attr_accessor :script_runner
    # A `->(element, src) {}` set by the integration layer to fetch + execute a
    # classic `<script src>` that's dynamically inserted into the document (e.g.
    # webpack/Vite loading an on-demand chunk via document.head.appendChild). It
    # owns firing the element's load / error event. nil = such scripts are inert.
    attr_accessor :external_script_runner

    def initialize(host = nil, backend_doc: nil, default_view: nil)
      @host = host
      @default_view = default_view
      @node_wrapper_cache = Internal::NodeWrapperCache.new(self)
      @observer_manager = Internal::ObserverManager.new
      @shadow_registry = Internal::ShadowRootRegistry.new
      @cookie_jar = Internal::CookieJar.new
      @template_content_registry = Internal::TemplateContentRegistry.new(self)
      @mutation_coordinator = Internal::MutationCoordinator.new(self, @observer_manager)
      @node_iterators = []
      @backend_doc = backend_doc || Backend.parse("<!doctype html><html><head></head><body></body></html>")
      @content_type = "text/html"
      # The document is fully parsed before scripts run (no incremental network
      # parse), so it defaults to "complete" — ready-gated code takes the
      # already-loaded path. An embedder can replay the real lifecycle
      # ("loading" → "interactive" → "complete") via #__internal_set_ready_state__
      # to drive code that waits on DOMContentLoaded / load.
      @ready_state = "complete"
      @__current_script__ = nil
    end

    # Whether this is an "HTML document" in the DOM sense (created by the HTML
    # parser / `text/html`), as opposed to an XML document. It drives the
    # case-folding rules: `createElement` lowercases names and `Element#tagName`
    # uppercases HTML-namespace names only in an HTML document. An XML or XHTML
    # document (e.g. an `application/xhtml+xml` / `text/xml` resource) preserves
    # case.
    def html_document?
      @content_type == "text/html"
    end

    # `document.compatMode` — "CSS1Compat" in no-quirks mode, "BackCompat" in
    # quirks mode. A missing doctype is quirks; a bare `<!DOCTYPE html>` (no
    # public/system identifier) is no-quirks. (The full quirks algorithm keys off
    # specific legacy public ids; this covers the common cases.)
    def compat_mode
      # Only HTML documents can be in quirks mode; an XML document
      # (createDocument / DOMParser XML) is always no-quirks.
      return "CSS1Compat" unless html_document?

      dt = @backend_doc.internal_subset
      return "BackCompat" unless dt
      return "CSS1Compat" if dt.name.to_s.downcase == "html" && dt.external_id.nil?

      "BackCompat"
    end

    # ----- Public Ruby API (snake_case) -----

    def title
      read_title
    end

    def title=(value)
      write_title(value.to_s)
    end

    def document_element
      # The document's root element — `<html>` for HTML, the actual root for XML.
      wrap_node(@backend_doc.root)
    end

    def head
      wrap_node(@backend_doc.at_css("head"))
    end

    # Resolve `body` fresh from the tree (not memoized) so it tracks a swapped
    # `<body>` — e.g. Turbo's page render does
    # `documentElement.replaceChild(newBody, body)`, after which a stale cached
    # wrapper would keep returning the detached old body. wrap_node caches by
    # node, so identity (`document.body === document.body`) still holds.
    def body
      wrap_node(@backend_doc.at_css("body"))
    end

    # The document's accessibility tree (built from <body>; the document itself
    # has no accessible node). See Internal::AccessibilityTree.
    def accessibility_tree
      Internal::AccessibilityTree.build(self)
    end
    alias_method :aria_tree, :accessibility_tree

    # A Playwright-compatible ARIA snapshot of the document.
    def aria_snapshot
      Internal::AriaSnapshot.serialize(accessibility_tree)
    end

    # Serialize the whole document to HTML (including the doctype).
    def to_html
      @backend_doc.to_html
    end

    # XPath queries returning wrapped nodes (Element / TextNode / etc).
    def at_xpath(expression)
      node = @backend_doc.at_xpath(expression)
      node && wrap_node(node)
    end

    def xpath(expression)
      @backend_doc.xpath(expression).map { |node| wrap_node(node) }
    end

    # `document.URL` / `documentURI` — both return location.href in
    # real browsers (legacy aliases of the same field). A document with no
    # browsing context (createDocument / new Document / DOMParser) has the URL
    # "about:blank", not the empty string.
    def url
      view = @default_view
      view&.location ? view.location.href : "about:blank"
    end

    alias document_uri url

    # `document.baseURI` — resolves the first `<base href>` (if any)
    # relative to the document URL; otherwise just the document URL.
    # When `<base href>` is itself absolute, that wins. Browsers also
    # ignore subsequent <base> elements; we mirror that.
    def base_uri
      doc_url = url
      base_el = @backend_doc.at_css("base[href]")
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
        @backend_doc.css("a[href], area[href]").map { |n| wrap_node(n) }.compact
      end
    end

    def forms
      HTMLCollection.new do
        @backend_doc.css("form").map { |n| wrap_node(n) }.compact
      end
    end

    def scripts
      HTMLCollection.new do
        @backend_doc.css("script").map { |n| wrap_node(n) }.compact
      end
    end

    def images
      HTMLCollection.new do
        @backend_doc.css("img").map { |n| wrap_node(n) }.compact
      end
    end

    # ParentNode mixin (operates on the document's element children —
    # in practice the `<html>` root).
    def children
      HTMLCollection.new do
        root = @backend_doc.root
        root ? [wrap_node(root)].compact : []
      end
    end

    # All child nodes of the document (doctype + document element, …), as a live,
    # cached NodeList — unlike `children`, which is element-only. Cached so
    # `document.childNodes === document.childNodes` and mutations are reflected.
    def child_nodes
      @live_child_nodes ||= LiveNodeList.new do
        @backend_doc.children.map { |n| wrap_node(n) }.compact
      end
    end

    def child_element_count
      children.size
    end

    def first_element_child
      wrap_node(@backend_doc.root)
    end

    def last_element_child
      wrap_node(@backend_doc.root)
    end

    # Currently-focused element (or body if none). Updated via
    # `el.focus()` / `el.blur()`.
    def active_element
      @active_element || body
    end

    # `document.contains(node)` — true if `node` is the document itself or any
    # node attached to its tree (per Node.contains, which all nodes including the
    # document expose). Per spec, false for null / a non-Node.
    def contains?(other)
      return true if other.equal?(self)
      return false unless other.respond_to?(:__dommy_backend_node__)

      # Walk parents up to the backend document node. (The backend's #ancestors
      # stops below the document, so it can't test document membership; the
      # doctype in particular reports an empty ancestor list.)
      node = other.__dommy_backend_node__
      node = node.parent while node && !node.equal?(@backend_doc)
      !node.nil?
    end

    def __internal_set_active_element__(el)
      # Focus is selector-observable state (:focus / :focus-within rules), so
      # a change invalidates computed styles.
      __internal_bump_style_generation__ unless @active_element.equal?(el)
      @active_element = el
    end

    # The explicitly focused element (nil when nothing holds focus) — what
    # :focus matches. Distinct from #active_element, which falls back to
    # <body> per spec.
    def __internal_focused_element__
      @active_element
    end

    # The element the (virtual) pointer hovers — :hover matches it and its
    # ancestors. Set from tests or capybara-dommy's Node#hover; nil clears.
    def __internal_hovered_element__
      @hovered_element
    end

    def __internal_set_hovered_element__(el)
      return if @hovered_element.equal?(el)

      @hovered_element = el
      __internal_bump_style_generation__
      nil
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
      TreeWalker.new(require_node_root(root), what_to_show, filter)
    end

    # The `root` of a TreeWalker / NodeIterator is a non-nullable WebIDL `Node`:
    # a null or non-Node argument is a TypeError before construction.
    def require_node_root(root)
      return root if root.is_a?(Dommy::Node)

      raise Bridge::TypeError, "createTreeWalker/createNodeIterator root must be a Node"
    end

    # WebIDL `unsigned long whatToShow = 0xFFFFFFFF`: an omitted or `undefined`
    # argument uses the default; `null` coerces to 0; otherwise ToUint32.
    def coerce_what_to_show(args, index)
      return NodeFilter::SHOW_ALL if args.length <= index
      value = args[index]
      return NodeFilter::SHOW_ALL if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)
      return 0 if value.nil?

      value.to_i % (2**32)
    end

    # A `null`/`undefined` filter argument means "no filter".
    def normalize_filter(value)
      return nil if value.nil?
      return nil if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)

      value
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
      return wrap_node(src) if src.document == @backend_doc

      # Cross-document: hand the detached source to the backend, which
      # returns the node now owned by this document — an imported copy for
      # Makiri (a node can't move between arenas). Drop the stale source
      # wrapper, then reseat the caller's Dommy wrapper onto the adopted
      # node so `adopt_node(x).equal?(x)` stays true across documents.
      src_doc_wrapper = node.instance_variable_get(:@document)
      adopted = Backend.adopt(src, @backend_doc)

      if src_doc_wrapper.respond_to?(:__internal_reset_wrapper__)
        src_doc_wrapper.__internal_reset_wrapper__(src)
      end
      node.instance_variable_set(:@document, self)
      node.instance_variable_set(:@__node__, adopted)
      @node_wrapper_cache.register(adopted, node)
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
      root = require_node_root(root)
      iterator = NodeIterator.new(root, what_to_show, filter)
      # The "NodeIterator pre-removing steps" run for iterators whose root's node
      # document is the removed node's document. Track the iterator on the root's
      # document — which is `self` for a same-document root, but a different
      # document when the root came from elsewhere (e.g.
      # implementation.createHTMLDocument), where the removal fires.
      node_iterator_document(root).__internal_track_node_iterator__(iterator)
      iterator
    end

    # The document that owns `root`'s subtree (where its removals fire), so a
    # NodeIterator is tracked where its pre-removing steps will run. Falls back
    # to `self` for a root with no resolvable document.
    def node_iterator_document(root)
      return root if root.is_a?(Dommy::Document)

      doc = root.instance_variable_get(:@document)
      doc.is_a?(Dommy::Document) ? doc : self
    end

    def __internal_track_node_iterator__(iterator)
      @node_iterators << iterator
    end

    # `document.doctype` — the node-backed DocumentType wrapping the parsed
    # `<!DOCTYPE …>` node, or nil when the document declares none (or the doctype
    # was removed, which unlinks the backend node). Shares wrapper identity with
    # the same node in `childNodes`, since both wrap the same backend node.
    def doctype
      node = Backend.internal_subset(@backend_doc)
      node ? wrap_node(node) : nil
    end

    def implementation
      @implementation ||= DOMImplementation.new(self)
    end

    def create_processing_instruction(target, data)
      @node_wrapper_cache.create_processing_instruction(target, data)
    end

    # Append a node as a child of the document itself (e.g. a comment alongside
    # the document element). Adopts the node into this document.
    def append_child(node)
      return node unless node.respond_to?(:__dommy_backend_node__)

      # appendChild adopts a node from another document (per spec). Only needed on
      # a backend that can't move a node across documents (Makiri).
      if !Backend.moves_nodes_across_documents? && node.respond_to?(:document) && !node.document.equal?(self)
        node = adopt_node(node)
      end
      @backend_doc.add_child(node.__dommy_backend_node__)
      node
    end

    # ParentNode / Node mutation on the document's direct children (the doctype
    # and the document element).
    def document_insert(args, prepend:)
      nodes = args.filter_map { |a| backend_node(a) }
      if prepend && (first = @backend_doc.children.first)
        nodes.reverse_each { |n| first.add_previous_sibling(n) }
      else
        nodes.each { |n| @backend_doc.add_child(n) }
      end
      nil
    end

    def document_replace_children(args)
      @backend_doc.children.each(&:unlink)
      args.filter_map { |a| backend_node(a) }.each { |n| @backend_doc.add_child(n) }
      nil
    end

    def document_remove_child(node)
      return __internal_remove_doctype__(node) if node.is_a?(DocumentType)

      bn = backend_node(node)
      raise DOMException::NotFoundError, "node is not a child of this document" unless bn && bn.parent == @backend_doc

      run_node_iterator_pre_remove(bn)
      bn.unlink
      node
    end

    def document_insert_before(node, ref)
      bn = backend_node(node)
      return node unless bn

      ref_node = ref && backend_node(ref)
      if ref_node && ref_node.parent == @backend_doc
        ref_node.add_previous_sibling(bn)
      else
        @backend_doc.add_child(bn)
      end
      node
    end

    def document_replace_child(new_child, old_child)
      old_bn = backend_node(old_child)
      raise DOMException::NotFoundError, "node is not a child of this document" unless old_bn && old_bn.parent == @backend_doc

      new_bn = backend_node(new_child)
      old_bn.add_previous_sibling(new_bn) if new_bn
      old_bn.unlink
      old_child
    end

    # Called by DocumentType#remove — unlink the backend doctype node so the tree
    # (and `document.doctype`, which re-derives from the tree) no longer sees it.
    def __internal_remove_doctype__(doctype)
      node = backend_node(doctype) || Backend.internal_subset(@backend_doc)
      return nil unless node

      run_node_iterator_pre_remove(node)
      node.unlink
      nil
    end

    # Called by DocumentType#before/#after — insert `nodes` before the doctype
    # (at the document start) or after it (just before the document element).
    def __internal_insert_at_doctype__(nodes, after:)
      bns = nodes.filter_map { |n| backend_node(n) }
      if after
        root = @backend_doc.root
        root ? bns.each { |n| root.add_previous_sibling(n) } : bns.each { |n| @backend_doc.add_child(n) }
      else
        first = @backend_doc.children.first
        first ? bns.reverse_each { |n| first.add_previous_sibling(n) } : bns.each { |n| @backend_doc.add_child(n) }
      end
      nil
    end

    # `document.cloneNode(deep)` → a fresh Document over a (deep) copy of the
    # Makiri tree, preserving the content type.
    def clone_node(deep)
      copy = deep ? Backend.clone_document(@backend_doc) : Backend.empty_document_like(@backend_doc)
      Document.new(nil, backend_doc: copy).tap { |d| d.content_type = @content_type }
    end

    def backend_node(node)
      node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : nil
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

    def get_elements_by_tag_name_ns(namespace, local_name)
      HTMLCollection.elements_by_tag_name_ns(@backend_doc, self, namespace, local_name)
    end

    # `document.write(html)` — legacy API. Appends parsed nodes to the
    # body. Real browsers only re-stream the DOM during initial parse;
    # this stub is enough for tests that fire write() during teardown.
    def write(*args)
      html = args.join
      fragment = Parser.fragment(html, owner_doc: @backend_doc)
      removed = []
      added = fragment.children.to_a
      body_node = body.__dommy_backend_node__
      added.each { |node| body_node.add_child(node) }
      notify_child_list_mutation(target_node: body_node, added_nodes: added, removed_nodes: removed)
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

    # Create a Comment node. Wraps the Makiri comment so it flows
    # through the same wrap_node identity machinery as Element / TextNode.
    def create_comment(text)
      @node_wrapper_cache.create_comment(text)
    end

    def create_cdata_section(text)
      # WHATWG: createCDATASection throws NotSupportedError on an HTML document
      # (CDATA sections exist only in XML). This also sidesteps Lexbor's HTML
      # serializer, which can't emit a CDATA node.
      raise DOMException::NotSupportedError, "createCDATASection is not supported on an HTML document" if html_document?

      str = text.to_s
      raise DOMException::InvalidCharacterError, "CDATA section data must not contain ']]>'" if str.include?("]]>")

      @node_wrapper_cache.create_cdata_section(str)
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
        body
      when "head"
        head
      when "doctype"
        doctype
      when "implementation"
        implementation
      when "defaultView"
        @default_view
      when "fullscreenElement"
        @fullscreen_element
      when "fullscreenEnabled"
        true
      when "scrollingElement"
        wrap_node(@backend_doc.at_css("html"))
      when "documentElement"
        # The document's root element — `<html>` for HTML, the actual root for XML.
        wrap_node(@backend_doc.root)
      when "title"
        read_title
      when "cookie"
        cookie
      when "nodeType"
        9
      when "nodeValue", "textContent"
        # A Document's nodeValue and textContent are null (not the concatenated
        # descendant text) per the DOM.
        nil
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
      when "location"
        # document.location is the same Location object as window.location.
        @default_view&.__js_get__("location")
      when "characterSet", "charset", "inputEncoding"
        # The DOM is held as Ruby strings (UTF-8); we don't model other encodings.
        "UTF-8"
      when "dir"
        document_element&.get_attribute("dir") || ""
      when "designMode"
        @design_mode || "off"
      when "lastModified"
        @last_modified || "01/01/1970 00:00:00"
      when "readyState"
        # "complete" by default (the document is fully parsed before scripts
        # run); an embedder can replay "loading" → "interactive" → "complete"
        # via #__internal_set_ready_state__.
        @ready_state
      when "visibilityState"
        # There's no real viewport/tab; the document is treated as the visible,
        # foreground page (so `nextRepaint`-style code uses requestAnimationFrame,
        # and `=== "visible"` checks pass).
        "visible"
      when "hidden"
        false
      when "compatMode"
        compat_mode
      when "referrer"
        referrer
      when "links"
        links
      when "forms"
        forms
      when "scripts"
        scripts
      when "currentScript"
        # The <script> currently executing, set by the host around each script
        # run (see #__internal_set_current_script__); null outside execution.
        @__current_script__
      when "images"
        images
      when "embeds", "plugins"
        # Both reflect the same list of <embed> elements.
        HTMLCollection.new { @backend_doc.css("embed").map { |n| wrap_node(n) }.compact }
      when "applets"
        # `<applet>` was removed from HTML, so this collection is always empty.
        HTMLCollection.new { [] }
      when "anchors"
        # Historically `<a name>` (with a name attribute), not every link.
        HTMLCollection.new { @backend_doc.css("a[name]").map { |n| wrap_node(n) }.compact }
      when "styleSheets"
        style_sheets
      when "children"
        children
      when "childNodes"
        child_nodes
      when "firstChild"
        child_nodes.to_a.first
      when "lastChild"
        child_nodes.to_a.last
      when "parentNode", "parentElement", "nextSibling", "previousSibling", "ownerDocument"
        # A document is the tree root: no parent or siblings, and its
        # ownerDocument is null per spec.
        nil
      when "childElementCount"
        child_element_count
      when "firstElementChild"
        first_element_child
      when "lastElementChild"
        last_element_child
      when "nodeName"
        "#document"
      else
        # WebIDL named getter: `document.someName` exposes a named embed / form /
        # iframe / img / object element (or an img/object by id). Unknown
        # otherwise → JS undefined.
        named = document_named_property(key.to_s)
        named.nil? ? Bridge::ABSENT : named
      end
    end

    # The document's supported property names (for `"name" in document`): the
    # `name` of each exposed element, plus the `id` of id-exposed img/object.
    def __js_named_props__
      names = []
      named_getter_nodes.each do |node|
        n = node["name"].to_s
        names << n unless n.empty?
        id = node["id"].to_s
        names << id if !id.empty? && %w[img object].include?(node.name.to_s.downcase) && !n.empty?
      end
      names.uniq
    end

    # Resolve a document named-getter property: nil when unsupported, a single
    # element (a named iframe yields its content window), or an HTMLCollection
    # when several elements share the name.
    def document_named_property(name)
      return nil if name.empty?

      matches = named_getter_nodes.select do |node|
        node["name"] == name ||
          (node["id"] == name && %w[img object].include?(node.name.to_s.downcase) && !node["name"].to_s.empty?)
      end
      wrapped = matches.map { |node| wrap_node(node) }.compact
      return nil if wrapped.empty?

      if wrapped.length == 1
        el = wrapped.first
        cw = el.respond_to?(:content_window) ? el.content_window : nil
        cw || el
      else
        HTMLCollection.new { document_named_property_nodes(name) }
      end
    end

    private

    # Elements the document's named getter exposes, in tree order.
    def named_getter_nodes
      @backend_doc.css("embed, form, iframe, img, object")
    end

    def document_named_property_nodes(name)
      named_getter_nodes.select do |node|
        node["name"] == name ||
          (node["id"] == name && %w[img object].include?(node.name.to_s.downcase) && !node["name"].to_s.empty?)
      end.map { |node| wrap_node(node) }.compact
    end

    public

    def __js_set__(key, value)
      case key
      when "title"
        write_title(value.to_s)
      when "cookie"
        self.cookie = value.to_s
      when "dir"
        document_element&.set_attribute("dir", value.to_s)
      when "designMode"
        # Enumerated: only "on"/"off" (case-insensitive), else ignored.
        v = value.to_s.downcase
        @design_mode = v if %w[on off].include?(v)
      when "location"
        # `document.location = url` navigates, same as `location.href = url`.
        loc = @default_view&.__js_get__("location")
        loc&.__js_set__("href", value)
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[
      exitFullscreen startViewTransition createElement createElementNS createTextNode
      createComment createCDATASection createProcessingInstruction createDocumentFragment querySelector querySelectorAll getElementById
      getElementsByClassName getElementsByTagName getElementsByTagNameNS getElementsByName createAttribute
      createAttributeNS createTreeWalker createNodeIterator createRange createEvent importNode
      adoptNode hasFocus getSelection elementFromPoint queryCommandSupported addEventListener
      removeEventListener dispatchEvent write writeln open close isEqualNode isSameNode appendChild
      hasChildNodes contains append prepend replaceChildren removeChild insertBefore replaceChild
      cloneNode normalize compareDocumentPosition getRootNode
    ]
    def __js_call__(method, args)
      case method
      when "getRootNode"
        # A document is its own root (no shadow tree above it), for any options.
        # Exposing this is load-bearing: React's resource hoisting computes its
        # "resource root" as `container.getRootNode()` and throws (#446) if the
        # document lacks it, falling back to the document's null ownerDocument.
        self
      when "hasChildNodes"
        @backend_doc.children.any?
      when "compareDocumentPosition"
        compare_document_position(args[0])
      when "contains"
        contains?(args[0])
      when "isEqualNode"
        is_equal_node(args[0])
      when "isSameNode"
        is_same_node(args[0])
      when "appendChild"
        append_child(args[0])
      when "append"
        document_insert(args, prepend: false)
      when "prepend"
        document_insert(args, prepend: true)
      when "replaceChildren"
        document_replace_children(args)
      when "removeChild"
        document_remove_child(args[0])
      when "insertBefore"
        document_insert_before(args[0], args[1])
      when "replaceChild"
        document_replace_child(args[0], args[1])
      when "cloneNode"
        clone_node(args[0])
      when "normalize"
        nil # the document has no text children to merge
      when "writeln"
        write(*(args + ["\n"]))
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
      when "createCDATASection"
        create_cdata_section(args[0])
      when "createProcessingInstruction"
        create_processing_instruction(args[0], args[1])
      when "createDocumentFragment"
        create_document_fragment
      when "querySelector"
        query_selector(Internal.css_query_arg!(args))
      when "querySelectorAll"
        query_selector_all(Internal.css_query_arg!(args))
      when "getElementById"
        get_element_by_id(args[0])
      when "getElementsByClassName"
        get_elements_by_class_name(args[0])
      when "getElementsByTagNameNS"
        get_elements_by_tag_name_ns(args[0], args[1])
      when "getElementsByTagName"
        get_elements_by_tag_name(args[0])
      when "getElementsByName"
        get_elements_by_name(args[0])
      when "createAttribute"
        create_attribute(args[0])
      when "createAttributeNS"
        create_attribute_ns(args[0], args[1])
      when "createTreeWalker"
        create_tree_walker(args[0], coerce_what_to_show(args, 1), normalize_filter(args[2]))
      when "createNodeIterator"
        create_node_iterator(args[0], coerce_what_to_show(args, 1), normalize_filter(args[2]))
      when "createRange"
        create_range
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
        remove_event_listener(args[0], args[1], args[2])
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

    # Replay a document-lifecycle transition: set readyState, fire
    # `readystatechange`, then the milestone event for the new state —
    # `DOMContentLoaded` (bubbles, dispatched on the document) when it becomes
    # "interactive", and `load` (on the window) when it becomes "complete". Lets
    # an embedder drive code that waits on the document lifecycle (Stimulus /
    # Turbo startup, jQuery `ready`, …). No-op when already in `state`.
    def __internal_set_ready_state__(state)
      state = state.to_s
      return if @ready_state == state

      @ready_state = state
      dispatch_event(Event.new("readystatechange"))
      case state
      when "interactive"
        dispatch_event(Event.new("DOMContentLoaded", "bubbles" => true))
      when "complete"
        @default_view&.dispatch_event(Event.new("load"))
      end
      nil
    end

    # Set `document.currentScript` to the <script> element being executed (and
    # back to nil afterward). The host (script boot) brackets each classic
    # script run with this so code reading `document.currentScript` sees its own
    # element, matching browser behavior.
    def __internal_set_current_script__(element)
      @__current_script__ = element
      nil
    end

    # Delegate node wrapping to NodeWrapperCache
    def wrap_node(node)
      @node_wrapper_cache.wrap(node)
    end

    def wrap_cloned_element_ns(node, namespace, prefix, local, qualified_name)
      @node_wrapper_cache.wrap_cloned_element_ns(node, namespace, prefix, local, qualified_name)
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

    # Every ShadowRoot attached in this document — the cascade collects each
    # one's <style> sheets and scopes them to that shadow tree.
    def __internal_all_shadow_roots__
      @shadow_registry.all
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

    # Unlink a backend node from its parent and queue a childList removal record
    # capturing the node's position (previous/next sibling) BEFORE the unlink, so
    # the record's previousSibling/nextSibling are correct (the coordinator can't
    # recover them once the node is detached). Used by every remove path.
    def remove_node_with_notify(node)
      parent = node.parent
      return unless parent

      prev_w = node.previous_sibling && wrap_node(node.previous_sibling)
      next_w = node.next_sibling && wrap_node(node.next_sibling)
      run_node_iterator_pre_remove(node)
      node.unlink
      notify_child_list_mutation(
        target_node: parent,
        added_nodes: [],
        removed_nodes: [node],
        previous_sibling: prev_w,
        next_sibling: next_w
      )
    end

    # Run the "NodeIterator pre-removing steps" for every live iterator before
    # `backend_node` is detached, so referenceNode/pointerBeforeReferenceNode
    # stay valid. `backend_node` must still be attached (tree intact) here.
    def run_node_iterator_pre_remove(backend_node)
      return if @node_iterators.empty?

      removed = wrap_node(backend_node)
      @node_iterators.each { |iter| iter.pre_remove(removed) }
    end

    def notify_attribute_mutation(target_node:, attribute_name:, old_value:, namespace: nil)
      @mutation_coordinator.notify_attribute_mutation(
        target_node: target_node,
        attribute_name: attribute_name,
        old_value: old_value,
        namespace: namespace
      )
    end

    def notify_character_data_mutation(target_node:, old_value:)
      @mutation_coordinator.notify_character_data_mutation(
        target_node: target_node,
        old_value: old_value
      )
    end

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

    # `document.styleSheets` — the CSSStyleSheet of each <style> and
    # <link rel=stylesheet> in document order (CSSOM). Computed on access so
    # it reflects the current tree.
    def style_sheets
      sheets = query_selector_all("style, link").filter_map do |element|
        element.sheet if element.respond_to?(:sheet)
      end
      NodeList.new(sheets)
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

    # Build a Nokogiri copy of the given node inside our @backend_doc.
    # `deep: true` recurses into children. Used by importNode and
    # adoptNode for cross-document transfer.
    def clone_into_doc(source, deep)
      copy = if source.element?
        new_el = Backend.create_element(source.name, @backend_doc)
        Backend.attribute_nodes(source).each { |a| new_el[a.name] = a.value }
        new_el
      elsif source.text?
        Backend.create_text(source.content, @backend_doc)
      elsif source.is_a?(Backend.comment_class)
        Backend.create_comment(source.content, @backend_doc)
      elsif source.is_a?(Backend.document_fragment_class)
        # A DocumentFragment clones to a fragment (its children are appended by
        # the deep pass below), NOT to its first child — `importNode(<template>
        # .content, true)` must return a fragment so `.firstElementChild` works
        # (Vue/Alpine x-for clone template content this way). Built via the
        # document's own `fragment` (as TemplateContentRegistry does) rather than
        # `document_fragment_class.new`, so it works on backends whose fragment
        # class isn't directly instantiable (Makiri).
        @backend_doc.fragment("")
      else
        # Fallback: serialize + reparse via fragment for unusual types.
        fragment = Parser.fragment(source.to_html, owner_doc: @backend_doc)
        fragment.children.first || Backend.create_text("", @backend_doc)
      end

      if source.element? && source.name == "template"
        # A <template>'s contents live in a separate content fragment, not its
        # child list, so the generic deep pass over `children` misses them.
        clone_template_content(source, copy) if deep
      elsif deep && source.respond_to?(:children)
        source.children.each do |child|
          copy.add_child(clone_into_doc(child, true))
        end
      end

      copy
    end

    # Clone a <template>'s content into a fragment registered as `copy`'s
    # template content. The source content lives backend-dependently — Makiri
    # keeps it in a native content fragment, Nokogiri keeps it as direct children
    # before migration and in the registry after — so source it from the registry
    # fragment when migrated, else from Backend.template_content_nodes.
    def clone_template_content(source, copy)
      src_frag = @template_content_registry.raw_fragment_for(source)
      content_nodes = src_frag ? src_frag.children.to_a : Backend.template_content_nodes(source)
      return if content_nodes.empty?

      frag = @backend_doc.fragment("")
      content_nodes.each { |n| frag.add_child(clone_into_doc(n, true)) }
      @template_content_registry.store(copy, frag)
    end

    def read_title
      # The first title element in tree order (usually the head's), with its
      # child text content stripped and collapsed of ASCII whitespace per WHATWG.
      # ASCII whitespace is exactly tab/LF/FF/CR/space — NOT Ruby's String#strip
      # set, which also removes U+000B (vertical tab) and must be left intact.
      title = @backend_doc.at_css("title")
      return "" unless title

      title.text.gsub(/[\t\n\f\r ]+/, " ").gsub(/\A[\t\n\f\r ]+|[\t\n\f\r ]+\z/, "")
    end

    def write_title(value)
      head = @backend_doc.at_css("head")
      return unless head

      title = head.at_css("title")
      unless title
        title = Backend.create_element("title", @backend_doc)
        head.add_child(title)
      end

      title.children.each(&:unlink)
      title.add_child(Backend.create_text(value, @backend_doc))
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
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[skipTransition]
    def __js_call__(method, _args)
      case method
      when "skipTransition"
        skip_transition
      end
    end
  end
end
