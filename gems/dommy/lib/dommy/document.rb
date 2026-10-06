# frozen_string_literal: true

require "uri"
require "time"

require_relative "internal/node_wrapper_cache"
require_relative "internal/directionality"
require_relative "internal/node_factory"
require_relative "internal/mutation_coordinator"
require_relative "internal/shadow_root_registry"
require_relative "internal/cookie_jar"
require_relative "internal/node_traversal"
require_relative "internal/node_adopter"
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
    include Internal::LeafNode
    # A node-backed doctype is an ordinary ChildNode of the document, so
    # `before` / `after` / `replaceWith` go through the shared implementation —
    # which runs the parent's ensure-pre-insertion-validity and the live-range
    # insert steps, neither of which the old doctype-specific path did.
    include Internal::ChildNode

    # Mixed into a node-backed doctype only, so a synthetic one keeps Node's nil
    # `__dommy_backend_node__` and is treated as disconnected.
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

    # The document this doctype currently belongs to (nil for a detached
    # synthetic doctype). Lets a cross-document appendChild/insert detect that
    # the node must be adopted (re-created) into the destination backend.
    def document
      @document || @owner_document
    end

    # A doctype answers `document` from either of two ivars (a synthetic one has
    # only `@owner_document`), so an adopt has to move both.
    def __internal_reseat__(backend_node, document)
      super
      @owner_document = document
      nil
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
      return synthetic_insert(nodes, after: false) unless @__node__

      child_node_before(nodes)
    end

    def after(*nodes)
      return synthetic_insert(nodes, after: true) unless @__node__

      child_node_after(nodes)
    end

    def replace_with(*nodes)
      unless @__node__
        synthetic_insert(nodes, after: false)
        remove
        return nil
      end

      child_node_replace_with(nodes)
    end

    # A synthetic doctype — the fallback for a backend that cannot create a
    # doctype node — is not in the tree at all, so WHATWG's ChildNode methods
    # would return at step 2. Dommy has always inserted around the document
    # element instead; that stays until the fallback goes away.
    def synthetic_insert(nodes, after:)
      return nil unless @owner_document

      @owner_document.__internal_insert_at_doctype__(nodes, after: after)
      nil
    end
    private :synthetic_insert

    # A doctype is connected when its tree is a document's; a synthetic one is
    # never in a tree at all.
    def is_connected?
      get_root_node.is_a?(Dommy::Document)
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
      when "isConnected"
        is_connected?
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
        if node
          clone = DocumentType.new(backend_node: node, document: @document)
          # Register the wrapper against its backend node, so inserting the clone
          # into a tree and reading it back returns THIS object rather than a
          # freshly built one (`doc.replaceChildren(dt); doc.firstChild === dt`).
          @document.__internal_register_wrapper__(node, clone)
          return clone
        end
      end
      DocumentType.new(name, public_id, system_id, owner_document: @owner_document)
    end

    include Bridge::Methods
    # WHATWG's own wording for a doctype parent.
    def leaf_insertion_message
      "a DocumentType may not have children"
    end
    private :leaf_insertion_message

    js_methods %w[isEqualNode isSameNode getRootNode hasChildNodes normalize compareDocumentPosition contains
      cloneNode appendChild insertBefore removeChild replaceChild before after replaceWith remove
      lookupNamespaceURI lookupPrefix isDefaultNamespace
      addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "lookupNamespaceURI"
        lookup_namespace_uri(args[0])
      when "lookupPrefix"
        lookup_prefix(args[0])
      when "isDefaultNamespace"
        is_default_namespace(args[0])
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
      when "appendChild"
        append_child(args[0])
      when "insertBefore"
        insert_before(args[0], args[1])
      when "replaceChild"
        replace_child(args[0], args[1])
      when "removeChild"
        remove_child(args[0])
      when "before"
        before(*args)
      when "after"
        after(*args)
      when "replaceWith"
        replace_with(*args)
      when "remove"
        remove
        Bridge::UNDEFINED # DocumentType (ChildNode)#remove is void -> JS undefined
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
    # the tree; otherwise it falls back to a synthetic one — the factory's own
    # (stricter, XML-flavoured) name check is not the DOM rule.
    def create_document_type(qualified_name, public_id, system_id)
      qn = qualified_name.to_s
      # A "valid doctype name" is extremely permissive — "1foo", "@foo",
      # "edi:%" and the empty string are all accepted — but refuses ASCII
      # whitespace, NULL and ">", which could not be serialized back.
      unless Internal::Namespaces.valid_doctype_name?(qn)
        raise DOMException::InvalidCharacterError, "invalid doctype name: #{qn.inspect}"
      end

      pub = public_id.to_s
      sys = system_id.to_s
      node =
        begin
          Backend.create_document_type(qn, pub, sys, @document.backend_doc)
        rescue ArgumentError
          nil
        end
      return DocumentType.new(qn, pub, sys, owner_document: @document) unless node

      # Seed the wrapper cache, or the doctype reached later through the tree
      # (document.childNodes, document.doctype, a NodeIterator) would be a
      # DIFFERENT DocumentType object than the one createDocumentType returned,
      # and `===` / `isSameNode` on the two would be false. Every other
      # create* goes through the cache; this one built its wrapper directly.
      wrapper = DocumentType.new(backend_node: node, document: @document)
      @document.__internal_register_wrapper__(node, wrapper)
      wrapper
    end

    # `hasFeature()` is a no-op that always returns true (DOM Standard).
    def has_feature(*)
      true
    end

    # createDocument(namespace, qualifiedName, doctype?) — a fresh XML document
    # with, in tree order, the doctype (when given) then a document element
    # (namespace, qualifiedName) when qualifiedName is non-empty.
    def create_document(namespace, qualified_name, doctype = nil)
      # WebIDL converts the interface argument before running the DOM steps
      # (including qualified-name validation).
      unless doctype.nil? || doctype.equal?(Bridge::UNDEFINED) || doctype.is_a?(DocumentType)
        raise Bridge::TypeError, "doctype must be a DocumentType"
      end

      doc = Document.new(nil, backend_doc: Backend.empty_xml_document)
      # The result is an XMLDocument (DOM's createDocument), unlike a DOMParser
      # result of the same content type — so the interface is pinned here.
      doc.__internal_xml_document__ = true
      # Its origin is the associated document's (DOM createDocument step 7).
      doc.__internal_set_creator__(@document)
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
        doc.backend_doc.add_child(el.__dommy_backend_node__)
      end
      adopt_doctype_into(doc, doctype)
      doc
    end

    # createHTMLDocument(title?) — a fresh HTML document (doctype + html > head,
    # body), with an optional <title>. A given title is a title element in the
    # head holding one Text node of exactly that data, "" included — which
    # the title setter's string-replace-all would leave empty.
    def create_html_document(title = nil)
      doc = Document.new(nil, backend_doc: Backend.parse("<!DOCTYPE html><html><head></head><body></body></html>"))
      # Its origin is the associated document's (DOM createHTMLDocument step 8).
      doc.__internal_set_creator__(@document)
      unless title.nil? || title.equal?(Bridge::UNDEFINED)
        element = doc.head.append_child(doc.create_element("title"))
        element.append_child(doc.create_text_node(title.to_s))
      end
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
        # namespace and qualifiedName are required (either may be null, but
        # must be present); doctype is optional.
        raise Bridge::TypeError, "createDocument requires 2 arguments." if args.length < 2

        create_document(args[0], args[1], args[2])
      when "createHTMLDocument"
        # title is an OPTIONAL DOMString: a missing or undefined argument leaves
        # the document title-less, but an explicit null coerces to "null".
        if args.empty? || args[0].equal?(Bridge::UNDEFINED)
          create_html_document
        else
          create_html_document(args[0].nil? ? "null" : args[0])
        end
      when "hasFeature"
        has_feature
      end
    end

    private

    # Place `doctype` (a DocumentType passed to createDocument) as `doc`'s first
    # child. createDocument appends the doctype node itself (step 5, before
    # step 6 appends the element), so it goes through the ordinary insert: the
    # adoption re-binds the caller's wrapper, and `xmlDoc.firstChild ===
    # doctype`, its parentNode and ownerDocument all follow.
    #
    # No-op for nil/undefined. Any other non-DocumentType is a TypeError: the
    # IDL converts `doctype` to `DocumentType?`, so `createDocument(ns, name,
    # false)` throws rather than ignoring the value. A doctype the XML backend
    # cannot hold is left unplaced rather than thrown: only an XML
    # serialization would validate its contents.
    def adopt_doctype_into(doc, doctype)
      return if doctype.nil? || doctype.equal?(Bridge::UNDEFINED)

      doc.insert_before(doctype, doc.document_element)
    rescue DOMException::NotSupportedError
      nil
    end
  end

  # `document` — the entry point for DOM construction and querying.
  # Wrapper caching keeps DOM identity stable across repeated
  # traversals (`body.children[0].parentElement`).
  #
  # The three Internal mixins below are state the whole DOM reaches into the
  # document for. It was reached through fifty-eight distinct `__internal_*`
  # seams, fifty of them called from outside this file; grouping them by
  # subject is what makes it possible to ask which collaborator needs which.
  class Document
    include Internal::DocumentGenerations
    include Internal::DocumentLiveRanges
    include Internal::DocumentInteractionState
    include EventTarget
    include Node

    attr_reader :backend_doc
    attr_accessor :default_view

    # The document URLs that have nothing to resolve a relative URL against, and
    # so borrow their creator's base URL (see #base_uri).
    FALLBACK_BASE_URLS = %w[about:blank about:srcdoc].freeze

    # --- CSS cascade support (Internal::CSS) ---
    # Two invalidation epochs, split so a style-neutral mutation doesn't pay
    # for a cascade rebuild (RuleIndex.build is a full rules x document query):
    #
    # `dom_generation` keys the selector-result caches (query caches, selector
    # index). It moves on anything that can change what a selector matches:
    # tree shape, attributes, focus/hover, checkedness, and text edits that
    # flip a node between empty and non-empty (`:empty` is the matcher's only
    # text-sensitive pseudo-class).
    #
    # `style_generation` keys the cascade caches (RuleIndex, computed styles,
    # counters — the slot itself is owned by Internal::CSS::Cascade). It moves
    # on the same events, EXCEPT that an attribute change only moves it when
    # the built RuleIndex's selectors depend on that attribute, and a text
    # edit only when it's inside a <style> or flips emptiness while a sheet
    # uses `:empty`. The coordinator reports mutations through the
    # `__internal_note_*` seams below, which decide what to bump.
    attr_accessor :__internal_css_style_cache__







    # The document's <style> and <link> elements in document order (their
    # relative order breaks cascade ties), memoized per tree_generation:
    # only a childList mutation can change the list, so the cascade's
    # attribute-triggered rebuilds reuse it without a document walk.
    def __internal_style_sheet_elements__
      if @__sheet_elements_gen != tree_generation
        @__sheet_elements_gen = tree_generation
        @__sheet_elements = query_selector_all("style, link").to_a
      end
      @__sheet_elements
    end









    # A by-id/class/tag index of the backend element tree, memoized per DOM
    # generation, for SelectorMatcher's document-scoped fast path (or nil to tell
    # the caller to walk). Rebuilt lazily only after a mutation bumps
    # dom_generation, so it costs one tree walk per generation and pays off when
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
      gen = dom_generation
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

      @__sel_idx ||= Internal::SelectorIndex.build(@backend_doc, quirks: quirks_mode?)
      @__sel_idx_served += 1
      @__sel_idx
    end

    # An element-scoped querySelector(All) result cache (the document-rooted one
    # lives in NodeWrapperCache). jQuery `$(el).find(sel)` re-queries the same
    # (element, selector) constantly between mutations; this memoizes the match
    # set, keyed by [scope object_id, kind, selector] and tagged with the DOM
    # generation, so a hit skips the whole combinator match. Capped, and a
    # mutation (dom_generation bump) makes every entry stale at once.
    SCOPED_QUERY_CACHE_CAP = 4096

    def __internal_scoped_query_get(key)
      entry = (@__scoped_query_cache ||= {})[key]
      entry && entry[0] == dom_generation ? entry[1] : nil
    end

    def __internal_scoped_query_set(key, value)
      cache = (@__scoped_query_cache ||= {})
      cache.clear if cache.size >= SCOPED_QUERY_CACHE_CAP
      cache[key] = [dom_generation, value]
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
    attr_reader :content_type

    # Whether the document is an HTML one rides on its type, and with it its
    # mode — only an HTML document can be in quirks mode — and how selectors
    # fold id and class case. A layer that sets the type after the parse
    # (dommy-rack does) has the mode worked out again and the selector
    # results retired.
    def content_type=(value)
      return if value == @content_type

      @content_type = value
      @quirks_mode = nil
      __internal_note_selector_state_change__
    end
    # A `->(source_text) {}` set by the JS layer to execute a classic <script>'s
    # body when it's connected (Dommy has no JS engine of its own). nil = inert
    # scripts (the default for a standalone DOM).
    attr_accessor :script_runner
    # A `->(element, src) {}` set by the integration layer to fetch + execute a
    # classic `<script src>` that's dynamically inserted into the document (e.g.
    # webpack/Vite loading an on-demand chunk via document.head.appendChild). It
    # owns firing the element's load / error event. nil = such scripts are inert.
    attr_accessor :external_script_runner

    # Installed by the browser when a JS runtime is present: re-runs the
    # inline-handler scan so an `on*` attribute that arrived after boot (a cloned
    # template, an innerHTML fragment) is compiled. nil without a runtime, which
    # is also the fast path that keeps a JS-free document out of this entirely.
    attr_accessor :inline_handler_wirer

    def __internal_wire_inline_handlers__
      @inline_handler_wirer&.call
      nil
    end

    def initialize(host = nil, backend_doc: nil, default_view: nil)
      @host = host
      @default_view = default_view
      @node_wrapper_cache = Internal::NodeWrapperCache.new(self)
      @node_factory = Internal::NodeFactory.new(self, @node_wrapper_cache)
      @observer_manager = Internal::ObserverManager.new
      @shadow_registry = Internal::ShadowRootRegistry.new
      @cookie_jar = Internal::CookieJar.new
      @template_content_registry = Internal::TemplateContentRegistry.new(self)
      @mutation_coordinator = Internal::MutationCoordinator.new(self, @observer_manager)
      # Weak, like @live_ranges: a NodeIterator is consulted by every removal for
      # as long as its document holds it, and detach() is a no-op by definition,
      # so a strong list would mean every iterator ever created keeps costing
      # work — and keeps its referenceNode's whole detached subtree alive —
      # forever. A browser collects an unreachable one and stops consulting it.
      @node_iterators = ObjectSpace::WeakMap.new
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

    # Whether this document is DOM's XMLDocument — the interface
    # `implementation.createDocument` returns (and a clone of one keeps). A
    # DOMParser result is the base Document even when parsed from XML, so this
    # rides on the instance rather than the content type. Together with
    # #html_document? it decides the document's most-derived interface.
    def xml_document? = @xml_document == true

    def __internal_xml_document__=(value)
      @xml_document = value
    end

    # `document.compatMode` — "BackCompat" in quirks mode, "CSS1Compat" in
    # no-quirks and limited-quirks mode alike.
    def compat_mode
      quirks_mode? ? "BackCompat" : "CSS1Compat"
    end

    # Whether the document is in quirks mode (DOM's "mode"). Only the HTML
    # parser puts a document in it, from the doctype it read — a missing one,
    # or one of HTML's legacy public identifiers (§13.2.6.4.1); the backend's
    # parser has already run that algorithm. Every other document is in
    # no-quirks mode, and a clone takes its original's mode. The mode is fixed
    # once known: changing the doctype later does not change it.
    def quirks_mode?
      return @quirks_mode unless @quirks_mode.nil?

      @quirks_mode = html_document? && Backend.quirks_mode?(@backend_doc)
    end

    def __internal_quirks_mode__=(value)
      @quirks_mode = value
    end

    # The document's character encoding, as an Encoding Standard name. Dommy
    # holds the DOM as UTF-8 and models no other encoding; this is the one place
    # HTML's "encoding-parse a URL" reads it from (see Element#resolve_url), so a
    # future non-UTF-8 document has a single place to teach.
    def character_encoding
      "UTF-8"
    end

    # ----- Public Ruby API (snake_case) -----

    def title
      read_title
    end

    # `document.dir` reflects the html element's `dir` content attribute,
    # limited to only known values. With no html element it reads "" and
    # ignores writes.
    def dir
      root = html_element
      root ? Internal::Directionality.reflected_dir(root) : ""
    end

    def dir=(value)
      html_element&.__internal_set_attribute_value__("dir", value.to_s)
    end

    # Whether designMode is "on", which makes the whole document editable.
    def __internal_design_mode__? = @design_mode == "on"

    def title=(value)
      write_title(value.to_s)
    end

    # A document is its own shadow-including root, so it is always connected
    # (Element#is_connected? walks up to a document; the document itself is the
    # base case).
    def is_connected?
      true
    end

    def document_element
      # The document's root element — `<html>` for HTML, the actual root for XML.
      # It is the document's first ELEMENT child, so a document that has none
      # answers null: the backend's `root` falls back to the doctype once the
      # element is gone (`document.removeChild(documentElement)`, or a
      # replaceChild that swaps it for a comment), and head / body / title
      # resolve through this (#backend_document_element).
      root = backend_document_element
      root && wrap_node(root)
    end

    # HTML's "the head element": the first `head` child, in the HTML
    # namespace, of the html element (readonly — assignment is a no-op, see
    # __js_set__).
    #
    # Spec: https://html.spec.whatwg.org/multipage/dom.html#the-head-element-2
    def head
      wrap_node(html_element_child(%w[head]))
    end

    # HTML's "the body element": the first child of the html element — the
    # document element, if it is the HTML namespace's `html` — that is a
    # `body` or a `frameset` in the HTML namespace; nil without one. Resolved
    # fresh from the tree (not memoized) so it tracks a swapped `<body>` — e.g.
    # Turbo's page render does `documentElement.replaceChild(newBody, body)`.
    # wrap_node caches by node, so `document.body === document.body` holds.
    #
    # Spec: https://html.spec.whatwg.org/multipage/dom.html#the-body-element-2
    def body
      wrap_node(html_element_child(%w[body frameset]))
    end

    # The body setter: the new value must be a `body` or a `frameset` in the
    # HTML namespace. It replaces the body element there is, or else is
    # appended to the document element; without either, there is nowhere to
    # put it.
    #
    # Spec: https://html.spec.whatwg.org/multipage/dom.html#dom-document-body
    def body=(element)
      raise DOMException::HierarchyRequestError, "body must be a body or frameset element" unless body_or_frameset?(element)

      current = body
      return if element.equal?(current)
      return current.parent_node.replace_child(element, current) if current

      root = document_element
      raise DOMException::HierarchyRequestError, "the document has no document element" unless root

      root.append_child(element)
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
      return view.location.href if view&.location

      @creator_url || "about:blank"
    end

    # A document made by a parsing or creation API (DOMParser,
    # DOMImplementation) takes its origin from `document` — the relevant
    # global object's associated Document — and, for DOMParser, its URL too.
    def __internal_set_creator__(document, url: nil)
      @origin_document = document
      @creator_url = url
      nil
    end

    alias document_uri url

    # `document.baseURI` — resolves the first `<base href>` (if any)
    # relative to the document URL; otherwise just the document URL.
    # When `<base href>` is itself absolute, that wins. Browsers also
    # ignore subsequent <base> elements; we mirror that.
    def base_uri
      doc_url = creator_base_url || url
      base_el = @backend_doc.at_css("base[href]")
      return doc_url unless base_el

      href = Backend.no_namespace_attribute_value(base_el, "href").to_s
      return doc_url if href.empty?

      # HTML "document base URL": the frozen base URL is the href parsed
      # against the document's URL; one that does not parse falls back.
      URL.new(href, doc_url.to_s.empty? ? nil : doc_url).href
    rescue Bridge::TypeError
      doc_url
    end

    # HTML's "fallback base URL": a document whose URL is `about:blank` or
    # `about:srcdoc` has no URL to resolve anything against, so it uses the base
    # URL of the document that created it — the iframe's own document. Set when
    # the nested browsing context is built; nil for a document that was fetched.
    def __internal_set_creator_base_url__(href)
      @creator_base_url = href
      nil
    end

    # `document.domain` — the effective domain of the document's origin
    # serialized: the domain a `document.domain =` set, or else the origin's
    # host; "" for an opaque origin.
    def domain
      return @domain_override if @domain_override

      host = Internal::Origin.host_of(origin)
      host.nil? ? "" : host.to_s
    end

    # The `document.domain` setter. It needs a browsing context and a tuple
    # origin, and accepts only the current effective domain or a registrable
    # suffix of it (everything else is a SecurityError). The agent cluster is
    # site-keyed (no Origin-Agent-Cluster header), so the domain is then set.
    #
    # Without a public suffix list, a single label (a bare TLD such as "com")
    # stands in for the public suffix.
    def domain=(value)
      view = @default_view
      raise DOMException::SecurityError, "The document has no browsing context" unless view&.navigable?

      current = Internal::Origin.host_of(origin)
      raise DOMException::SecurityError, "The document's origin is opaque" if current.nil?

      candidate = value.to_s
      unless registrable_domain_suffix_or_equal?(candidate, current.to_s)
        raise DOMException::SecurityError, "'#{candidate}' is not a suffix of '#{current}'"
      end

      @domain_override = Internal::UrlParser.parse("http://#{candidate}/").host.to_s
    end

    # `document.origin` — this document's origin, serialized (the same answer as
    # `self.origin`). Empty when there is no associated window.
    def origin
      view = @default_view
      return @origin_document&.origin.to_s unless view&.location

      view.origin
    end

    # `document.lastModified` — the source's last modification (the response's
    # Last-Modified header, when the embedder passed one on), else the current
    # time, in local time as "MM/DD/YYYY hh:mm:ss".
    #
    # Spec: https://html.spec.whatwg.org/#dom-document-lastmodified
    def last_modified
      (@last_modified_time || Time.now).getlocal.strftime("%m/%d/%Y %H:%M:%S")
    end

    # Record the document's source last-modified time: a Time, or an HTTP date
    # string (a Last-Modified header value). One that does not parse leaves it
    # unknown.
    def __internal_set_last_modified__(value)
      @last_modified_time =
        case value
        when Time then value
        when nil then nil
        else
          begin
            Time.httpdate(value.to_s.strip)
          rescue ArgumentError
            nil
          end
        end
      nil
    end

    # `document.referrer` — the URL of the document that navigated here, as the
    # embedder reports it (`__internal_referrer__=`); empty when there was none.
    def referrer
      @referrer.to_s
    end

    def __internal_referrer__=(url)
      @referrer = url
    end

    # Whether the document has completely finished loading: its `load` event
    # has been fired. A document whose lifecycle no one replays is born loaded.
    def __internal_completely_loaded__?
      !@loading_lifecycle
    end

    # Live HTMLCollection helpers — each call re-queries the
    # document so post-mutation reads reflect the current state.
    #
    # Each of these is defined as a collection of HTML ELEMENTS, and a `css`
    # query matches on local name alone: SVG has its own `a`, `script` and
    # `image`, so an SVG `<script>` would otherwise arrive in `document.scripts`
    # as an SVGElement and be asked for `type` (WPT's moveBefore/
    # script-move-before.html has one, and the NoMethodError took the file's
    # whole harness with it).
    # Each of these is [SameObject] in the IDL, so it is cached: the collection's
    # block re-runs on every access, keeping it live while giving the same
    # object back (`document.forms === document.forms`).
    def links
      @links ||= HTMLCollection.new do
        @backend_doc.css("a[href], area[href]").filter_map { |n| __internal_html_element_wrapper__(n) }
      end
    end

    def forms
      @forms ||= HTMLCollection.new do
        @backend_doc.css("form").filter_map { |n| __internal_html_element_wrapper__(n) }
      end
    end

    def scripts
      @scripts ||= HTMLCollection.new do
        @backend_doc.css("script").filter_map { |n| __internal_html_element_wrapper__(n) }
      end
    end

    def images
      @images ||= HTMLCollection.new do
        @backend_doc.css("img").filter_map { |n| __internal_html_element_wrapper__(n) }
      end
    end

    # ParentNode mixin (operates on the document's element children —
    # in practice the `<html>` root).
    def children
      @live_children ||= HTMLCollection.new do
        root = backend_document_element
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

    # A document has at most one element child, the document element.
    def first_element_child = document_element

    def last_element_child = document_element


    # `document.contains(node)` — true if `node` is the document itself or any
    # node attached to its tree (per Node.contains, which all nodes including the
    # document expose). Per spec, false for null / a non-Node.
    def contains?(other)
      return true if other.equal?(self)
      return false unless other.is_a?(Node)

      # Whose root the backend document node is. (The backend's #ancestors
      # stops below the document, so it can't test document membership; the
      # doctype in particular reports an empty ancestor list.)
      node = other.__dommy_backend_node__
      !node.nil? && Internal::NodeTraversal.root_of(node).equal?(@backend_doc)
    end





    # Create a detached Attr. `setAttributeNode` attaches it to an
    # element. Per spec, name must match the XML Name production —
    # invalid names throw InvalidCharacterError.
    def create_attribute(name)
      @node_factory.create_attribute(name)
    end

    def create_attribute_ns(namespace_uri, qualified_name)
      @node_factory.create_attribute_ns(namespace_uri, qualified_name)
    end

    # `document.createTreeWalker(root, whatToShow?, filter?)` — stateful
    # tree traversal with sibling/parent navigation. `filter` may be a
    # Ruby Proc, a JS-bridge callable, or an object with
    # `accept_node` / `acceptNode`.
    def create_tree_walker(root, what_to_show = NodeFilter::SHOW_ALL, filter = nil)
      TreeWalker.new(Internal::WebIDL.node!(root), what_to_show, filter)
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
      # Step 1: "If node is a document or shadow root, throw a
      # NotSupportedError." Neither has anywhere to go in another document.
      if node.is_a?(Document) || node.is_a?(ShadowRoot)
        raise DOMException::NotSupportedError, "a #{node.is_a?(Document) ? "document" : "shadow root"} cannot be imported"
      end

      # An Attr is a Node but not a backend-tree node: it is copied by rebuilding
      # it here with the same qualified name, namespace, prefix and value, owned
      # by no element (importNode never attaches the copy to anything).
      return import_attribute(node) if node.is_a?(Attr)
      return nil unless node.is_a?(Node) && node.__dommy_backend_node__

      # WebIDL `optional boolean deep = false`: a missing / undefined argument
      # is the default (false / shallow), not a truthy sentinel.
      deep = false if deep.nil? || deep.equal?(Bridge::UNDEFINED)
      source_document = node.respond_to?(:document) ? node.document : self
      copy = clone_into_doc(node.__dommy_backend_node__, deep, source_document)
      apply_imported_cloning_steps(node.__dommy_backend_node__, copy, deep, source_document)
      wrap_node(copy)
    end

    def import_attribute(attr)
      Attr.new(
        attr.name,
        value: attr.value,
        namespace_uri: attr.namespace_uri,
        prefix: attr.prefix,
        local_name: attr.local_name,
        document: self
      )
    end

    # The registry holding this document's `<template>` content fragments. A
    # cross-document clone or adopt has to read the SOURCE document's registry:
    # template contents are not in the template's child list, so they are
    # reachable only through the registry that owns them.
    def __internal_template_registry__
      @template_content_registry
    end

    # Move a node from another document into this one. The source node is
    # detached from its previous owner and its ownerDocument becomes this.
    # Returns the (possibly re-bound) node.
    #
    # What "moving" costs depends on the backend — an import plus a walk to
    # carry the live wrappers and template contents over, where a browser swaps
    # a pointer — so the whole of it lives in Internal::NodeAdopter.
    def adopt_node(node)
      node_adopter.adopt(node)
    end

    # Adopt a raw backend node with no wrapper of its own: a DocumentFragment's
    # children, on a cross-document insert.
    def __internal_adopt_backend_node__(node, source_document)
      node_adopter.adopt_backend_node(node, source_document)
    end

    # HTML "cloning steps": a cloned node copies interface-specific live state
    # that the content attributes don't capture — an input's dirty value and
    # checkedness, a textarea's dirty value, etc. Dommy keeps that state on the
    # Ruby wrapper (not the backend node), and a deep backend clone never calls
    # the descendants' clone_node, so walk the original and cloned subtrees in
    # lockstep and copy each live wrapper's cloning state onto its copy. `deep`
    # false processes only the root (a shallow clone has no children).
    def __internal_apply_cloning_steps__(src_root_bn, clone_root_bn, deep)
      src_nodes = deep ? Internal::NodeTraversal.subtree_nodes(src_root_bn) : [src_root_bn]
      clone_nodes = deep ? Internal::NodeTraversal.subtree_nodes(clone_root_bn) : [clone_root_bn]
      return unless src_nodes.length == clone_nodes.length

      src_nodes.zip(clone_nodes).each do |orig, copy|
        # HTML cloning steps for <template>: the backend's clone copies an HTML
        # document's contents itself, but an XML document's live apart from
        # the node, so a deep clone copies them across explicitly (a shallow
        # clone gets an empty template, per spec).
        clone_template_content(orig, copy) if deep && @template_content_registry.detached?(orig)

        wrapper = @node_wrapper_cache.peek(orig)
        next unless wrapper.respond_to?(:__internal_cloning_state__)

        state = wrapper.__internal_cloning_state__
        next if state.nil?

        @node_wrapper_cache.wrap(copy).__internal_apply_cloning_state__(state)
      end
    end

    # Legacy `document.createEvent("EventName")` factory. The DOM Standard
    # matches the type ASCII case-insensitively against a fixed alias table, and
    # throws NotSupportedError for anything else — including the plural forms it
    # does not list. Returns an *uninitialized* event: the interface's own init
    # method (initEvent, initMouseEvent, …) has to be called before dispatch.
    CREATE_EVENT_ALIASES = {
      "event" => Event,
      "events" => Event,
      "htmlevents" => Event,
      "svgevents" => Event,
      "beforeunloadevent" => BeforeUnloadEvent,
      "compositionevent" => CompositionEvent,
      "customevent" => CustomEvent,
      "devicemotionevent" => DeviceMotionEvent,
      "deviceorientationevent" => DeviceOrientationEvent,
      "dragevent" => DragEvent,
      "focusevent" => FocusEvent,
      "hashchangeevent" => HashChangeEvent,
      "keyboardevent" => KeyboardEvent,
      "messageevent" => MessageEvent,
      "mouseevent" => MouseEvent,
      "mouseevents" => MouseEvent,
      "storageevent" => StorageEvent,
      "textevent" => TextEvent,
      "touchevent" => TouchEvent,
      "uievent" => UIEvent,
      "uievents" => UIEvent
    }.freeze

    def create_event(type_name)
      klass = CREATE_EVENT_ALIASES[type_name.to_s.downcase(:ascii)]
      raise DOMException::NotSupportedError, "The provided event type is not supported" if klass.nil?

      # createEvent hands back an *uninitialized* event: it has no type yet and
      # dispatching it before initEvent() is an InvalidStateError.
      event = klass.new("")
      event.__internal_mark_uninitialized__
      event
    end

    # Stubs for layout / focus / selection / execCommand APIs that
    # don't apply to a layout-less DOM. They exist so callers don't
    # hit NoMethodError; semantics are documented as no-op.

    # `document.hasFocus()` — HTML's "has focus steps", with the top-level
    # page always holding system focus: a document with no browsing context
    # has no focus, a top-level one has it, and a nested one has it when its
    # frame is the focused element of a parent document that has it.
    #
    # Spec: https://html.spec.whatwg.org/#has-focus-steps
    def has_focus?
      view = @default_view
      return false unless view

      frame = view.frame_element
      return true unless frame
      return false unless frame.is_connected?

      parent = frame.owner_document
      parent.has_focus? && parent.__internal_focused_element__.equal?(frame)
    end

    alias has_focus has_focus?

    # A document without a browsing context (one built by DOMParser or
    # createHTMLDocument) has no selection.
    def get_selection
      return nil unless @default_view

      @__selection ||= Selection.new(self)
    end

    def create_range
      Range.new(self)
    end

    # The showing popovers and the state that orders their showing and
    # hiding (Internal::PopoverStack).
    def __internal_popover_stack__
      @popover_stack ||= Internal::PopoverStack.new
    end

    # Fullscreen API — no actual fullscreen mode, just track which
    # element claimed it. `element.requestFullscreen()` sets it; this
    # is the read side.
    attr_reader :fullscreen_element

    def __internal_set_fullscreen_element__(element)
      previous = @fullscreen_element
      @fullscreen_element = element
      return if previous == element

      # :fullscreen and :modal match the fullscreen element.
      __internal_note_selector_state_change__
      dispatch_event(Event.new("fullscreenchange"))
    end

    def exit_fullscreen
      return PromiseValue.resolve(@default_view, nil) if @fullscreen_element.nil?

      @fullscreen_element = nil
      __internal_note_selector_state_change__
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
      root = Internal::WebIDL.node!(root)
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

      doc = root.document if root.respond_to?(:document)
      doc.is_a?(Dommy::Document) ? doc : self
    end

    def __internal_track_node_iterator__(iterator)
      @node_iterators[iterator] = true
    end

    def node_iterators?
      @node_iterators.size.positive?
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
      @node_factory.create_processing_instruction(target, data)
    end

    # WHATWG "ensure pre-insertion validity", step 6 — the Document-parent
    # constraints an element-like parent doesn't have. `args` is the set of nodes
    # (and DOMStrings) being inserted; per "converting nodes into a node" they're
    # summed as one insertion. `child_bn` is the backend reference child (nil for
    # append). `ignore_existing` (replaceChildren) drops the current children
    # from the counts, since replace-all removes them first. `exclude` (replace)
    # is a current child to disregard. Raises HierarchyRequestError on violation.
    def ensure_document_insertion_validity!(args, child_bn, ignore_existing: false, exclude: nil)
      ensure_not_self_insertion!(args)
      elements = 0
      doctypes = 0
      has_text = false
      args.each do |arg|
        case arg
        when String
          has_text = true
        when Dommy::Fragment
          arg.child_nodes.each do |c|
            if c.is_a?(Dommy::Element) then elements += 1
            elsif c.is_a?(Dommy::DocumentType) then doctypes += 1
            elsif c.is_a?(Dommy::TextNode) then has_text = true
            end
          end
        when Dommy::DocumentType then doctypes += 1
        when Dommy::Element then elements += 1
        when Dommy::CharacterDataNode
          # Comment (8) / PI (7) are valid document children; Text (3) is not.
          has_text = true if arg.node_type == 3
        when Dommy::Node
          # A Document / Attr / anything else is not an insertable node type.
          raise DOMException::HierarchyRequestError, "This node type cannot be inserted here."
        end
      end

      # `existing` (with positions) drives the "doctype following / element
      # preceding child" checks; those use the FULL child list, since `child`
      # (the reference / node being replaced) is still in the tree. The
      # "already has an element/doctype child" checks, however, disregard the
      # node being replaced (`exclude`) — WHATWG replace's "...child that is not
      # child" wording.
      existing = ignore_existing ? [] : @backend_doc.children.to_a
      has_element = existing.any? { |c| c.node_type == 1 && !(exclude && c == exclude) }
      has_doctype = existing.any? { |c| c.node_type == 10 && !(exclude && c == exclude) }

      # Step 6, Text/DocumentFragment-with-text: no text under a document.
      raise DOMException::HierarchyRequestError, "A Text node cannot be a child of a document." if has_text

      if doctypes.positive?
        if doctypes > 1 || elements.positive? || has_doctype ||
           element_before_child?(existing, child_bn) ||
           (child_bn.nil? && has_element)
          raise DOMException::HierarchyRequestError, "A doctype cannot be inserted here."
        end
      end

      if elements > 1
        raise DOMException::HierarchyRequestError, "Only one element may be a child of a document."
      elsif elements == 1 &&
            (has_element || (child_bn && child_bn.node_type == 10) || doctype_after_child?(existing, child_bn))
        raise DOMException::HierarchyRequestError, "An element cannot be inserted here."
      end

      ensure_doctypes_have_nodes!(args)
    end

    # Not a DOM step, and checked after all of them so a HierarchyRequestError
    # still wins: a synthetic doctype — one the backend could not create, which
    # today means only an empty name (Makiri refuses it; the DOM allows it) —
    # has no node to put in the tree. Inserting it would do nothing (and a
    # replace would drop the node it replaces), so it is refused outright.
    # createDocument, which the DOM never lets throw here, catches this and
    # leaves the doctype out.
    def ensure_doctypes_have_nodes!(args)
      return unless args.any? { |a| a.is_a?(Dommy::DocumentType) && a.__dommy_backend_node__.nil? }

      raise DOMException::NotSupportedError, "This doctype cannot be inserted: the backend could not create it."
    end

    # Document's answer to the ParentNode hook a ChildNode mutation
    # (`before` / `after` / `replaceWith`) calls on its parent. A Document
    # parent skips the ancestor rule (it is never a descendant of anything) and
    # instead carries step 6: at most one element child, no Text child, and a
    # doctype only ahead of the document element. `replacing` is the child a
    # `replaceWith` stands in for, which WHATWG "replace" disregards when
    # counting the existing children.
    def __internal_ensure_insertion_validity__(args, ref_bn, replacing: nil)
      ensure_document_insertion_validity!(args, ref_bn, exclude: replacing)
    end

    # WHATWG "ensure pre-insertion validity" step 2 for a Document parent: node
    # must not be a host-including inclusive ancestor of the parent. A document
    # is an inclusive ancestor of itself and nothing else can be an ancestor of
    # one, so this reduces to "you cannot insert the document into itself".
    #
    # It is step 2, so it precedes step 3's NotFoundError on the reference
    # child: `document.replaceChild(document, x)` is a HierarchyRequestError
    # even when x is not a child of the document.
    def ensure_not_self_insertion!(args)
      return unless args.any? { |a| a.equal?(self) }

      raise DOMException::HierarchyRequestError, "Cannot insert a node as a descendant of itself"
    end

    # Whether any element child precedes `child_bn` in the document's child list.
    def element_before_child?(existing, child_bn)
      idx = child_bn && existing.index { |c| c == child_bn }
      return false unless idx

      existing[0...idx].any? { |c| c.node_type == 1 }
    end

    # Whether any doctype child follows `child_bn` in the document's child list.
    def doctype_after_child?(existing, child_bn)
      idx = child_bn && existing.index { |c| c == child_bn }
      return false unless idx

      existing[idx..].any? { |c| c.node_type == 10 }
    end

    # Append a node as a child of the document itself (e.g. a comment alongside
    # the document element). Adopts the node into this document.
    def append_child(node)
      ensure_document_insertion_validity!([node], nil)
      return node unless node.is_a?(Node) && node.__dommy_backend_node__

      # An append has a null reference child, so insert step 5 shifts nothing.
      nodes = document_insertion_nodes([node])
      return node if nodes.empty?

      nodes.each { |bn| @backend_doc.add_child(bn) }
      notify_document_child_list(added: nodes)
      node
    end

    # The Node / ParentNode mutation methods under their WHATWG names. The
    # document's own child list has its own rules (at most one element, no Text,
    # a doctype only ahead of the document element), so each forwards to the
    # `document_*` implementation that carries them.
    def insert_before(node, reference)
      document_insert_before(node, reference)
    end

    def replace_child(new_child, old_child)
      document_replace_child(new_child, old_child)
    end

    def remove_child(node)
      document_remove_child(node)
    end

    def replace_children(*args)
      document_replace_children(args)
    end

    def append(*args)
      document_insert(args, prepend: false)
    end

    def prepend(*args)
      document_insert(args, prepend: true)
    end

    # WHATWG ParentNode.moveBefore(node, child) with the DOCUMENT as the new
    # parent. The move primitive's steps 5 and 6 bind only here: a Text node may
    # not become a child of a document, and an Element may only be moved in when
    # the document has no element child, the reference is not the doctype, and
    # no doctype follows the reference.
    #
    # Spec: https://dom.spec.whatwg.org/#dom-parentnode-movebefore
    def move_before(node, child = nil)
      Internal::WebIDL.node!(node)
      Internal::WebIDL.nullable_node!(child)
      bn = move_backend_node(node)
      ref_bn = move_backend_node(child)
      ref_bn = ref_bn.next_sibling if ref_bn && bn && ref_bn == bn
      ensure_document_move_validity!(node, bn, ref_bn)

      old_parent = bn.parent
      old_previous = bn.previous_sibling
      old_next = bn.next_sibling
      detach_node(bn, moving: true)                               # steps 10-11, 14
      ref_bn = nil if ref_bn && ref_bn.parent != @backend_doc
      __internal_ranges_will_insert__(@backend_doc, ref_bn, 1)    # step 16
      new_previous = ref_bn ? ref_bn.previous_sibling : @backend_doc.children.to_a.last
      ref_bn ? ref_bn.add_previous_sibling(bn) : @backend_doc.add_child(bn) # step 18
      if old_parent
        notify_child_list_mutation(
          target_node: old_parent, added_nodes: [], removed_nodes: [bn],
          previous_sibling: old_previous && wrap_node(old_previous),
          next_sibling: old_next && wrap_node(old_next), moving: true
        )
      end
      notify_document_child_list(added: [bn], previous_sibling: new_previous && wrap_node(new_previous),
                                 next_sibling: ref_bn && wrap_node(ref_bn), moving: true)
      __internal_notify_moved_subtree__(bn)                        # step 19.3, into a document
      nil
    end

    # The backend node an argument to `moveBefore` stands for. A
    # Dommy::Document's `__dommy_backend_node__` is nil, but it is a node the
    # algorithm has to see (step 2 rejects it, step 3 measures its parentage).
    def move_backend_node(value)
      return value.backend_doc if value.is_a?(Dommy::Document)

      value.__dommy_backend_node__ if value.is_a?(Node)
    end

    # "Move" steps 1-6 with a document new parent.
    def ensure_document_move_validity!(node, bn, ref_bn)
      # Step 1 — the same root. A document is its own root, so this says the
      # node must already be somewhere in this document.
      root = bn && Internal::NodeTraversal.root_of(bn)
      # `==` and not `equal?`: a backend may hand back a fresh Ruby object for
      # the same underlying node on every `parent` call.
      unless bn && root == @backend_doc
        raise DOMException::HierarchyRequestError,
              "moveBefore requires the node and the new parent to share a root"
      end

      # Step 2 — a document is its own inclusive ancestor; nothing else can be
      # an ancestor of one, so this reduces to "not the document itself".
      ensure_not_self_insertion!([node])

      # Step 3.
      if ref_bn && ref_bn.parent != @backend_doc
        raise DOMException::NotFoundError, "The reference child is not a child of this document."
      end

      # Step 4.
      unless node.is_a?(Dommy::Element) || node.is_a?(Dommy::CharacterDataNode)
        raise DOMException::HierarchyRequestError, "this node type cannot be moved"
      end

      # Step 5.
      if node.is_a?(Dommy::CharacterDataNode) && node.node_type == 3
        raise DOMException::HierarchyRequestError, "A Text node cannot be a child of a document."
      end

      return unless node.is_a?(Dommy::Element)

      # Step 6. The counts are of the CURRENT children, so a document that
      # already has a document element cannot take another element — not even
      # by moving that same element to a different slot.
      existing = @backend_doc.children.to_a
      return unless existing.any? { |c| c.node_type == 1 } ||
                    (ref_bn && ref_bn.node_type == 10) ||
                    doctype_after_child?(existing, ref_bn)

      raise DOMException::HierarchyRequestError, "An element cannot be moved here."
    end

    # ParentNode / Node mutation on the document's direct children (the doctype
    # and the document element).
    def document_insert(args, prepend:)
      ref_bn = prepend ? @backend_doc.children.first : nil
      ensure_document_insertion_validity!(args, ref_bn)
      __internal_ranges_will_insert__(@backend_doc, ref_bn, document_insertion_count(args))
      nodes = document_insertion_nodes(args)
      if prepend && (first = @backend_doc.children.first)
        nodes.reverse_each { |n| first.add_previous_sibling(n) }
      else
        nodes.each { |n| @backend_doc.add_child(n) }
      end
      notify_document_child_list(added: nodes)
      nil
    end

    def document_replace_children(args)
      # replaceChildren removes the current children first, so the validity
      # checks ignore them (whatwg/dom#1045).
      ensure_document_insertion_validity!(args, nil, ignore_existing: true)
      removed = @backend_doc.children.to_a
      removed.each { |child| detach_node(child) }
      added = document_insertion_nodes(args)
      added.each { |n| @backend_doc.add_child(n) }
      notify_document_child_list(added: added, removed: removed)
      nil
    end

    def document_remove_child(node)
      return __internal_remove_doctype__(node) if node.is_a?(DocumentType)

      bn = backend_node(node)
      raise DOMException::NotFoundError, "node is not a child of this document" unless bn && bn.parent == @backend_doc

      remove_node_with_notify(bn)
      node
    end

    def document_insert_before(node, ref)
      # WHATWG pre-insert order: step 2 (a cycle) first, THEN step 3 (the
      # reference child must be a child of the parent, NotFoundError), and only
      # then the node-type / document-hierarchy checks (steps 4-6).
      ensure_not_self_insertion!([node])
      ref_present = !(ref.nil? || (defined?(Bridge::UNDEFINED) && ref.equal?(Bridge::UNDEFINED)))
      ref_bn = ref_present ? backend_node(ref) : nil
      if ref_present && !(ref_bn && ref_bn.parent == @backend_doc)
        raise DOMException::NotFoundError, "The reference child is not a child of this document."
      end

      ensure_document_insertion_validity!([node], ref_bn)
      # Insert step 6's insertion point, read BEFORE step 7's adopt moves
      # anything: the reference child's previous sibling, or the document's last
      # child when appending.
      record_previous = document_insertion_previous_sibling(ref_bn)
      record_next = ref_bn && wrap_node(ref_bn)
      # Insert step 5 runs before step 7's adopt, so the count is taken while the
      # node (or fragment) still sits wherever it is now.
      __internal_ranges_will_insert__(@backend_doc, ref_bn, document_insertion_count([node]))
      nodes = document_insertion_nodes([node])
      return node if nodes.empty?

      ref_node = ref && backend_node(ref)
      if ref_node && ref_node.parent == @backend_doc
        nodes.each { |bn| ref_node.add_previous_sibling(bn) }
      else
        nodes.each { |bn| @backend_doc.add_child(bn) }
      end
      notify_document_child_list(added: nodes, previous_sibling: record_previous,
                                 next_sibling: record_next)
      node
    end

    def document_replace_child(new_child, old_child)
      # Step 2 (a cycle) precedes step 3 (the reference child's parentage).
      ensure_not_self_insertion!([new_child])
      old_bn = backend_node(old_child)
      raise DOMException::NotFoundError, "node is not a child of this document" unless old_bn && old_bn.parent == @backend_doc

      # replaceChild's validity disregards the node being replaced when counting
      # the document's existing element / doctype children.
      ensure_document_insertion_validity!([new_child], old_bn, exclude: old_bn)

      ref = old_bn.next
      # Replace step 4's previousSibling: the old child's previous sibling,
      # read before the adopt below removes anything.
      record_previous = old_bn.previous && wrap_node(old_bn.previous)
      record_next = ref && wrap_node(ref)
      cross_document = new_child.respond_to?(:document) && !new_child.document.equal?(self)
      fragment = new_child.is_a?(Dommy::Fragment)

      # Same document: WHATWG replace adopts the incoming node — which removes
      # it from whatever parent it has — BEFORE removing the child it replaces,
      # so that old parent gets its removing steps and its childList record.
      #
      # Cross-document is deferred instead: a doctype has to be re-created in
      # this backend, and Makiri's fail-closed guard refuses a second doctype,
      # so the old one must be gone before the new one is made.
      #
      # A DocumentFragment has nothing to adopt at this point: what gets
      # inserted is its children, and insert step 4 takes them out later, after
      # step 7 has removed the child being replaced.
      new_bn = adopted_backend_node(new_child) if !cross_document && !fragment
      # Insert step 2's count, taken while the fragment still holds its children.
      count = document_insertion_count([new_child])
      detach_node(old_bn)
      # Insert step 4: a fragment's children are REMOVED from it, which runs the
      # live range and NodeIterator pre-remove steps and queues a childList
      # record on the fragment. Then step 5 shifts the ranges on this document
      # by the count. WHATWG "replace" removes the old child (step 7) before the
      # insert (step 9), so step 5 measures `ref` in the tree the removal leaves.
      nodes =
        if fragment
          document_insertion_nodes([new_child])
        elsif cross_document
          new_child = adopt_node(new_child)
          bn = backend_node(new_child)
          bn ? [bn] : []
        else
          new_bn ? [new_bn] : []
        end
      __internal_ranges_will_insert__(@backend_doc, ref && ref.parent == @backend_doc ? ref : nil, count)
      nodes.each do |bn|
        ref && ref.parent == @backend_doc ? ref.add_previous_sibling(bn) : @backend_doc.add_child(bn)
      end
      notify_document_child_list(added: nodes, removed: [old_bn],
                                 previous_sibling: record_previous, next_sibling: record_next)
      old_child
    end

    # Called by DocumentType#remove — unlink the backend doctype node so the tree
    # (and `document.doctype`, which re-derives from the tree) no longer sees it.
    def __internal_remove_doctype__(doctype)
      node = backend_node(doctype) || Backend.internal_subset(@backend_doc)
      return nil unless node

      remove_node_with_notify(node)
      nil
    end

    # Called by DocumentType#before/#after — insert `nodes` before the doctype
    # (at the document start) or after it (just before the document element).
    def __internal_insert_at_doctype__(nodes, after:)
      bns = nodes.filter_map { |n| backend_node(n) }
      anchor = after ? backend_document_element : @backend_doc.children.first
      __internal_ranges_will_insert__(@backend_doc, anchor, bns.size)
      if after
        anchor ? bns.each { |n| anchor.add_previous_sibling(n) } : bns.each { |n| @backend_doc.add_child(n) }
      else
        anchor ? bns.reverse_each { |n| anchor.add_previous_sibling(n) } : bns.each { |n| @backend_doc.add_child(n) }
      end
      nil
    end

    # `document.cloneNode(deep)` → a fresh Document of the same kind, keeping
    # the content type. "Clone a single node" creates a document EMPTY, and a
    # deep clone then copies the original's children into it — so nothing
    # sprouts an html/head/body of its own, and a document with no children
    # clones to one with no children.
    def clone_node(deep)
      copy = Document.new(nil, backend_doc: Backend.empty_document_like(@backend_doc))
      copy.content_type = @content_type
      copy.__internal_xml_document__ = @xml_document
      copy.__internal_quirks_mode__ = quirks_mode?
      return copy unless deep

      child_nodes.each { |child| copy.append_child(copy.import_node(child, true)) }
      copy
    end

    def backend_node(node)
      node.__dommy_backend_node__ if node.is_a?(Node)
    end

    # Like `backend_node`, but first adopts a node that belongs to another
    # document (per the insert steps) — the document-child insert paths
    # (append / prepend / replaceChildren / insertBefore) need this exactly as
    # `append_child` does, otherwise a cross-document node's backend node comes
    # from a foreign arena and the insertion silently drops it on a backend that
    # can't move nodes across documents (Makiri).
    # WHATWG pre-insert: adopt the node into this document, which removes it
    # from whatever parent it has now. The backend would detach it implicitly on
    # the next add_child, but silently — that is a storage operation, not a DOM
    # removal, so route it through the shared remove primitive instead and let
    # the old parent see its removing steps and its childList record.
    # WHATWG "insert" steps 1 and 4 for the DOCUMENT's own child list. A
    # DocumentFragment argument contributes its children, and they are removed
    # from it first — with their removing steps, so a live range or NodeIterator
    # inside them follows — before anything is linked here. Every other node is
    # adopted, which removes it from its old parent.
    #
    # Document's insertion paths hand the backend the node they were given, and
    # the backend splices a fragment's children in silently; without this the
    # fragment's children would move with no removing steps at all.
    def document_insertion_nodes(args)
      args.flat_map do |arg|
        if arg.is_a?(Dommy::Fragment)
          source = arg.document
          arg.extract_children.map do |n|
            n.document == @backend_doc ? n : __internal_adopt_backend_node__(n, source)
          end
        else
          bn = adopted_backend_node(arg)
          bn ? [bn] : []
        end
      end
    end

    # How many nodes `args` will contribute, counted BEFORE any of them moves —
    # insert step 5 needs the count while the fragment still holds its children.
    def document_insertion_count(args) = Internal::InsertionPoint.count(args)

    def adopted_backend_node(node)
      return nil unless node.is_a?(Node) && node.__dommy_backend_node__

      if node.respond_to?(:document) && !node.document.equal?(self)
        return adopt_node(node)&.__dommy_backend_node__
      end

      bn = node.__dommy_backend_node__
      remove_node_with_notify(bn) if bn.parent
      bn
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
      @node_factory.create_element_ns(namespace_uri, qualified_name)
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

    # ----- Dynamic markup insertion (document.open / write / close) -----
    #
    # Dommy has no incremental parser, so this models the spec's input stream
    # without one:
    #
    # - While the page's own scripts boot (readyState "loading" and a script
    #   running) the parser counts as active with a script nesting level above
    #   0: `open()` is a no-op that returns the document, and `write()` inserts
    #   the parsed markup right after the running script (where the insertion
    #   point would be), or at the end of the body when that script is not in
    #   the body.
    # - Otherwise `write()` with no script-created parser runs the document open
    #   steps first (the page is gone), and every write re-parses the whole
    #   input written since `open()` as a fresh document, whose children replace
    #   the document's. Earlier writes' nodes are therefore not the same objects
    #   after a later write, and scripts in written markup do not run.
    #
    # Spec: https://html.spec.whatwg.org/#dynamic-markup-insertion

    # `document.write(...text)` — the document write steps with lineFeed false.
    def write(*args)
      document_write(args, line_feed: false)
    end

    # `document.writeln(...text)` — the document write steps with lineFeed true.
    def writeln(*args)
      document_write(args, line_feed: true)
    end

    # `document.open()` — the document open steps; returns the document. With
    # three arguments it is `window.open(url, name, features)` instead.
    #
    # Spec: https://html.spec.whatwg.org/#dom-document-open
    def open(*args)
      return open_window(args) if args.length >= 3

      document_open_steps
    end

    # `document.close()` — closes the input stream a script-created parser
    # reads: the parser reaches EOF and "stops parsing", so the document goes
    # "interactive" (DOMContentLoaded) then "complete" (load at the window,
    # when there is one). Dispatched synchronously rather than as queued tasks.
    #
    # Spec: https://html.spec.whatwg.org/#dom-document-close
    def close
      raise DOMException::InvalidStateError, "close() is not supported on an XML document" unless html_document?
      return nil if @script_created_input.nil?

      # The parser reaches EOF. With nothing written it has seen no doctype
      # (quirks mode) and, into an empty document, builds html/head/body.
      if @script_created_input.empty?
        if @backend_doc.children.to_a.empty?
          reparse_script_created_input
        else
          @quirks_mode = true
        end
      end
      @script_created_input = nil
      __internal_set_ready_state__("interactive")
      __internal_set_ready_state__("complete")
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
      # WebIDL DOMString: JS null coerces to "null" (undefined -> "undefined").
      @node_factory.create_comment(text.nil? ? "null" : text)
    end

    def create_cdata_section(text)
      # WHATWG: createCDATASection throws NotSupportedError on an HTML document
      # (CDATA sections exist only in XML). This also sidesteps Lexbor's HTML
      # serializer, which can't emit a CDATA node.
      raise DOMException::NotSupportedError, "createCDATASection is not supported on an HTML document" if html_document?

      str = text.to_s
      raise DOMException::InvalidCharacterError, "CDATA section data must not contain ']]>'" if str.include?("]]>")

      @node_factory.create_cdata_section(str)
    end

    def create_document_fragment
      @node_factory.create_document_fragment
    end

    def get_elements_by_class_name(name)
      @node_wrapper_cache.get_elements_by_class_name(name)
    end

    def __js_get__(key)
      if key.start_with?("on") && key.length > 2
        # An event handler IDL attribute (GlobalEventHandlers /
        # DocumentAndElementEventHandlers, plus onreadystatechange and
        # onvisibilitychange): the registered handler, or null when unset —
        # matching Element's on* getter.
        return @on_handlers&.[](event_name_from_on(key))
      end

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
        document_element
      when "title"
        read_title
      when "dir"
        dir
      when "cookie"
        cookie
      when "nodeType"
        9
      when "isConnected"
        # A document is its own shadow-including root, so it is always connected.
        true
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
        character_encoding
      when "designMode"
        @design_mode || "off"
      when "lastModified"
        last_modified
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
        # Both reflect the same [SameObject] list of <embed> elements.
        @embeds ||= HTMLCollection.new { @backend_doc.css("embed").map { |n| wrap_node(n) }.compact }
      when "applets"
        # `<applet>` was removed from HTML, so this [SameObject] collection is
        # always empty.
        @applets ||= HTMLCollection.new { [] }
      when "anchors"
        # Historically `<a name>` (with a name attribute), not every link.
        @anchors ||= HTMLCollection.new { @backend_doc.css("a[name]").map { |n| wrap_node(n) }.compact }
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

    # The document's supported property names (for `"name" in document`): for
    # each exposed element in tree order, its id when it is a named element with
    # that name, then its name.
    def __js_named_props__
      names = []
      named_getter_nodes.each do |node|
        id = Backend.no_namespace_attribute_value(node, "id").to_s
        names << id if named_element?(node, id)
        name = Backend.no_namespace_attribute_value(node, "name").to_s
        names << name if named_element?(node, name)
      end
      names.uniq
    end

    # Resolve a document named-getter property: nil when unsupported, a single
    # element (a named iframe yields its content window), or an HTMLCollection
    # when several elements share the name.
    def document_named_property(name)
      return nil if name.empty?

      wrapped = document_named_property_nodes(name)
      return nil if wrapped.empty?
      return HTMLCollection.new { document_named_property_nodes(name) } unless wrapped.length == 1

      el = wrapped.first
      # Only an iframe's named property is its content window; an object's is
      # the element itself.
      el.local_name.to_s.casecmp?("iframe") && el.respond_to?(:content_window) ? (el.content_window || el) : el
    end

    def __js_set__(key, value)
      if key.start_with?("on") && key.length > 2
        # `document.onXxx = fn` registers fn as a single named handler; nil
        # removes it. Without this the assignment became a plain JS expando and
        # the handler never fired (e.g. `document.onreadystatechange`).
        set_on_handler(event_name_from_on(key), value)
        return nil
      end

      case key
      when "title"
        write_title(value.to_s)
      when "cookie"
        self.cookie = value.to_s
      when "dir"
        self.dir = value
      when "designMode"
        # Enumerated: only "on"/"off" (case-insensitive), else ignored.
        v = value.to_s.downcase
        @design_mode = v if %w[on off].include?(v)
      when "domain"
        self.domain = value.to_s
      when "location"
        # `document.location = url` navigates, same as `location.href = url`.
        loc = @default_view&.__js_get__("location")
        loc&.__js_set__("href", value)
      when "body"
        # WebIDL `attribute HTMLElement? body`: anything but an HTMLElement or
        # null fails the conversion before the setter's own checks run.
        raise Bridge::TypeError, "document.body must be an HTMLElement or null" unless value.nil? || value.is_a?(HTMLElement)

        self.body = value
      when "head", "documentElement"
        # Readonly attributes: assignment is a silent no-op. Handle it here so the
        # bridge doesn't store a JS-side expando that would shadow the getter.
        nil
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
      cloneNode normalize compareDocumentPosition getRootNode moveBefore
      lookupNamespaceURI lookupPrefix isDefaultNamespace
    ]
    def __js_call__(method, args)
      case method
      when "lookupNamespaceURI"
        lookup_namespace_uri(args[0])
      when "lookupPrefix"
        lookup_prefix(args[0])
      when "isDefaultNamespace"
        is_default_namespace(args[0])
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
        raise Bridge::TypeError, "insertBefore requires 2 arguments." if args.length < 2
        Internal::WebIDL.nullable_node!(args[1])

        document_insert_before(args[0], args[1])
      when "replaceChild"
        document_replace_child(args[0], args[1])
      when "moveBefore"
        raise Bridge::TypeError, "moveBefore requires 2 arguments." if args.length < 2

        move_before(args[0], args[1])
        Bridge::UNDEFINED
      when "cloneNode"
        clone_node(args[0])
      when "normalize"
        normalize
      when "writeln"
        writeln(*args)
        Bridge::UNDEFINED
      when "exitFullscreen"
        exit_fullscreen
      when "startViewTransition"
        # View Transitions API stub. Spec: invoke the callback
        # synchronously; return a ViewTransition with already-resolved
        # `finished` / `ready` / `updateCallbackDone` promises.
        callback = args[0]
        CallableInvoker.invoke(callback)

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
        Bridge::UNDEFINED
      when "open"
        open(*args)
      when "close"
        close
        Bridge::UNDEFINED
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
      @loading_lifecycle = true if state == "loading"
      dispatch_event(Event.new("readystatechange"))
      case state
      when "interactive"
        dispatch_event(Event.new("DOMContentLoaded", "bubbles" => true))
      when "complete"
        fire_load_and_pageshow
      end
      nil
    end

    # The end of loading, from "update the current document readiness to
    # complete": fire a trusted `load` at the window with the legacy target
    # override (so `event.target` is this document), then `pageshow` (persisted
    # false), and mark the document completely loaded — ready for post-load
    # tasks such as a print() requested while it loaded.
    def fire_load_and_pageshow
      view = @default_view
      if view
        load = Event.new("load")
        load.__internal_set_target__(self)
        view.dispatch_event(load.__internal_mark_trusted__)
        view.dispatch_event(__internal_page_transition_event__("pageshow"))
      end
      @loading_lifecycle = false
      view.__internal_ready_for_post_load_tasks__ if view.respond_to?(:__internal_ready_for_post_load_tasks__)
    end
    private :fire_load_and_pageshow

    # A trusted page transition event (`pageshow` / `pagehide`) for this
    # document's window: bubbles, cancelable, `persisted` false (there is no
    # back/forward cache), targeted at the document (legacy target override).
    def __internal_page_transition_event__(type, persisted: false)
      event = PageTransitionEvent.new(type, "persisted" => persisted, "bubbles" => true, "cancelable" => true)
      event.__internal_set_target__(self)
      event.__internal_mark_trusted__
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

    # The task scheduler this document's own tasks run on: its browsing context's
    # when it has one, otherwise the one handed to it by whatever built it (a
    # DOMParser document has no defaultView but still queues tasks on the window
    # whose script created it).
    attr_writer :task_scheduler

    def __internal_scheduler__
      (@default_view&.scheduler if @default_view.respond_to?(:scheduler)) || @task_scheduler
    end

    # The parser built the tree without any insertion or attribute steps
    # running: give the elements that depend on them their due, once the
    # document exists. Every details gets its insertion steps (the toggle event
    # it owes, its exclusive accordion group settled), every select has its
    # list of options settled (a single-select the parser left with no, or
    # several, selected options), and every script has its "force async" flag
    # cleared (HTML §4.12.1.1: the HTML/XML parser clears it on every element it
    # inserts, so a plain parsed `<script>` reports `.async === false`).
    def __internal_run_parsed_insertion_steps__
      # HTML-namespace only: a `css` query matches on local name, so a
      # `<details>` the parser put inside `<svg>` answers it too, as an
      # SVGElement that has none of these steps.
      elements = @backend_doc.css("details").filter_map { |node| __internal_html_element_wrapper__(node) }
      HTMLDetailsElement.run_insertion_steps(elements) unless elements.empty?
      @backend_doc.css("select").each { |node| __internal_html_element_wrapper__(node)&.__internal_settle_selectedness_once__ }
      @backend_doc.css("script").each { |node| __internal_html_element_wrapper__(node)&.__internal_mark_parser_inserted__ }
      @backend_doc.css("meta[http-equiv]").each { |node| __internal_html_element_wrapper__(node)&.__internal_run_pragma__ }
      # Each element the parser inserted with an autofocus attribute is an
      # autofocus candidate (only in a document with a browsing context).
      @backend_doc.css("[autofocus]").each do |node|
        element = wrap_node(node)
        __internal_autofocus_inserted__(element) if element.respond_to?(:autofocus) && element.is_connected?
      end
      nil
    end

    # HTML's pragma-set default language (`<meta http-equiv=content-language
    # content=…>`): nil until such a pragma has been processed.
    attr_accessor :__internal_pragma_default_language__

    # DOMParser parses with scripting disabled (HTML) or XML scripting support
    # disabled, so every script it makes is "already started": moved or cloned
    # into a document that runs scripts, it still does not run. Found by local
    # name, so an XML document's prefixed `h:script` counts too.
    def __internal_mark_scripts_already_started__
      Internal::NodeTraversal.subtree_nodes(@backend_doc).each do |node|
        next unless node.element?
        next unless node.local_name == "script"

        wrapper = wrap_node(node)
        next unless wrapper.respond_to?(:__internal_mark_script_already_started__)

        wrapper.__internal_mark_script_already_started__
        wrapper.__internal_mark_parser_inserted__
      end
      nil
    end

    # The wrapper for a backend node, but only when HTML's rules are the ones
    # that apply to it.
    #
    # Every query that finds elements by name — `css("details")`,
    # `document.scripts`, a select's list of options — finds the SVG ones too,
    # because a local name is all a backend node carries and the namespace lives
    # on the wrapper. So `createElementNS(SVG_NS, "details")` answers a
    # `css("details")` as an SVGElement, which has none of the methods HTML's
    # steps call, and the NoMethodError escapes into the page: WPT's
    # clicking-noninteractive-unlabelable-content.html appends exactly that
    # element to a <label>, and testharness turned the whole file's results into
    # one ERROR.
    #
    # The one place the question can be asked, because the wrapper is where the
    # answer is — hence a seam rather than a private method: PostInsertionSteps
    # asks it too.
    def __internal_html_element_wrapper__(node)
      wrapper = wrap_node(node)
      wrapper if wrapper.is_a?(Element) && Internal::ElementState.html_element?(wrapper)
    end

    # Bind an externally built wrapper to its backend node, so later traversals
    # return the same Ruby object (JS identity) instead of building a new one.
    def __internal_register_wrapper__(node, wrapper)
      @node_wrapper_cache.register(node, wrapper)
      wrapper
    end

    # Clear the cached wrapper so the next `wrap_node` creates a new
    # one. Used by `customElements.define` to upgrade nodes that were
    # constructed before the registration landed.
    def __internal_reset_wrapper__(nokogiri_node)
      @node_wrapper_cache.reset_wrapper(nokogiri_node)
    end

    def __internal_peek_wrapper__(nokogiri_node)
      @node_wrapper_cache.peek(nokogiri_node)
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

    def __internal_shadow_root_for_host__(host_node)
      @shadow_registry.find_for_host(host_node)
    end

    # Every element among `root`'s shadow-including inclusive descendants, as
    # backend nodes, in shadow-including tree order: an element, then the shadow
    # tree it hosts, then its children. The whole list, shadow trees included, is
    # taken before the first element is yielded. Callbacks run synchronously here,
    # and one that attaches a shadow root or inserts elements triggers those
    # changes' own reactions; walking into them as well would run them twice.
    def __internal_each_shadow_including_element__(root, &block)
      shadow_including_elements(root).each(&block)
      nil
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

    # The custom element reactions of a move (moveBefore), for a node that ended
    # up connected.
    def __internal_notify_moved_subtree__(nk)
      @mutation_coordinator.notify_moved_subtree(nk)
    end

    def __internal_notify_disconnected_subtree__(nk)
      @mutation_coordinator.notify_disconnected_subtree(nk)
    end

    def __internal_notify_attribute_changed__(element, name, old_value, new_value, namespace = nil)
      @mutation_coordinator.notify_attribute_changed(element, name, old_value, new_value, namespace)
    end

    def register_observer(observer)
      @mutation_coordinator.register_observer(observer)
    end

    def unregister_observer(observer)
      @mutation_coordinator.unregister_observer(observer)
    end

    # Queue the childList record for a mutation. The live-range insertion steps
    # are NOT run here: WHATWG puts them at insert step 5, before the nodes are
    # converted and linked, so every insertion site calls
    # __internal_ranges_will_insert__ itself, at that point.
    def notify_child_list_mutation(
      target_node:,
      added_nodes:,
      removed_nodes:,
      previous_sibling: nil,
      next_sibling: nil,
      moving: false
    )
      @mutation_coordinator.notify_child_list_mutation(
        target_node: target_node,
        added_nodes: added_nodes,
        removed_nodes: removed_nodes,
        previous_sibling: previous_sibling,
        next_sibling: next_sibling,
        moving: moving
      )
    end

    # WHATWG "removing steps", run while `node` is STILL attached (they are all
    # expressed in terms of the position it is about to vacate). Every path that
    # takes a node out of its parent — an explicit removeChild, the implicit
    # removal a move performs, replaceChildren, textContent=, fragment
    # extraction — must go through here, or a live Range / NodeIterator anchored
    # in the vacated position is left pointing at a detached node.
    #
    # A document with no live range and no NodeIterator has nothing to observe
    # the vacated position, so the whole thing collapses to two predicate calls
    # — this runs once per removed node, and a bulk replaceChildren /
    # textContent= must not pay for machinery nobody is watching.
    def pre_remove_node(node)
      return nil if !node_iterators? && !live_ranges?
      return nil unless node.parent

      run_node_iterator_pre_remove(node)
      __internal_ranges_will_remove__(node)
      nil
    end

    # A childList mutation on the DOCUMENT's own child list (its doctype, the
    # document element, a stray comment). Document-level mutation is observable
    # like any other — `observe(document, {childList: true})` is legal — so it
    # goes through the same pipeline rather than only nudging live ranges.
    # Insert step 6 for a document parent: the reference child's previous
    # sibling, or the document's last child when appending.
    def document_insertion_previous_sibling(ref_bn)
      node = Internal::InsertionPoint.previous_sibling(@backend_doc, ref_bn)
      node && wrap_node(node)
    end

    def notify_document_child_list(added: [], removed: [], previous_sibling: nil, next_sibling: nil, moving: false)
      notify_child_list_mutation(
        target_node: @backend_doc,
        added_nodes: added,
        removed_nodes: removed,
        previous_sibling: previous_sibling,
        next_sibling: next_sibling,
        moving: moving
      )
    end

    # The single detach primitive: pre-removing steps, then unlink. Callers that
    # batch several removals into one childList record (replaceChildren,
    # textContent=, replaceChild) use this and queue the record themselves;
    # `remove_node_with_notify` is this plus a per-node record.
    #
    # `moving:` marks the first half of the "move" primitive (moveBefore). A
    # move takes the node out of its old parent's children only to put it
    # straight back into the same shadow-including tree: it never leaves the
    # document, so nothing that reacts to a removal from the document may run.
    def detach_node(node, moving: false)
      pre_remove_node(node)
      add_transient_observers_for(node)
      node.unlink
      # A removal can take a shadow tree, and a selection range in it, out of
      # the document without moving the range; the selection lets go of it.
      @__selection&.__internal_node_removed__ unless moving
      node
    end

    # WHATWG remove step 20: every subtree registration reachable from the old
    # parent's inclusive ancestors gains a transient registered observer on the
    # node being removed, so a subtree observer keeps seeing mutations inside
    # the just-removed subtree until the next microtask checkpoint.
    #
    # The step is NOT guarded by suppressObservers (only step 21's record is),
    # so it has to run here, in the removal primitive, rather than alongside the
    # record. Replace all step 3, insert step 4 and replace step 7 all remove
    # with observers suppressed.
    def add_transient_observers_for(node)
      return unless @observer_manager.any?

      parent = node.parent
      return unless parent

      target = wrap_node(parent)
      removed = wrap_node(node)
      return unless target && removed

      @observer_manager.observers_matching(target).each do |observer|
        entry = observer.find_matching_entry(target)
        observer.add_transient(removed, entry) if entry && entry[:subtree]
      end
    end

    # The document write steps (without Trusted Types).
    #
    # Spec: https://html.spec.whatwg.org/#document-write-steps
    def document_write(args, line_feed:)
      string = args.map { |a| a.nil? ? "null" : a.to_s }.join
      string += "\n" if line_feed
      raise DOMException::InvalidStateError, "write() is not supported on an XML document" unless html_document?

      return boot_script_write(string) if @script_created_input.nil? && boot_script_running?

      document_open_steps if @script_created_input.nil?
      # The open steps return early (no script-created parser) only when the
      # parser is active, which the branch above already took.
      return nil if @script_created_input.nil?

      @script_created_input << string
      reparse_script_created_input
      nil
    end

    # Whether a page script is running while the page boots: the closest Dommy
    # has to "an active parser whose script nesting level is greater than 0".
    def boot_script_running?
      @ready_state == "loading" && !@__current_script__.nil?
    end

    # The document open steps, minus what Dommy does not model (the origin
    # check against the entry document, unload counters, stopping a
    # navigation, and the URL and history update steps).
    #
    # Spec: https://html.spec.whatwg.org/#document-open-steps
    def document_open_steps
      raise DOMException::InvalidStateError, "open() is not supported on an XML document" unless html_document?
      return self if boot_script_running?
      # A second open() while a script-created parser is open keeps it (the
      # spec's steps re-run, but the written input so far is already gone with
      # the children they replace).
      erase_all_event_listeners_and_handlers
      document_replace_children([])
      @quirks_mode = false
      @script_created_input = +""
      unless @ready_state == "loading"
        @ready_state = "loading"
        dispatch_event(Event.new("readystatechange"))
      end
      self
    end

    # Insert what a boot-time script wrote at the insertion point: right after
    # the running script when it sits in the body, else at the end of the body
    # (or of the document element when there is no body).
    def boot_script_write(string)
      script_bn = @__current_script__&.__dommy_backend_node__
      parent_bn = script_bn&.parent
      in_body = parent_bn && body && parent_bn != @backend_doc &&
                Internal::NodeTraversal.subtree_nodes(body.__dommy_backend_node__).include?(parent_bn)
      target_bn = in_body ? parent_bn : (body || document_element)&.__dommy_backend_node__
      return nil unless target_bn

      context = target_bn.element? ? target_bn : nil
      added = Parser.fragment(string, owner_doc: @backend_doc, context: context).children.to_a
      return nil if added.empty?

      if in_body
        reference = script_bn
        added.each do |node|
          reference.add_next_sibling(node)
          reference = node
        end
      else
        added.each { |node| target_bn.add_child(node) }
      end
      notify_child_list_mutation(target_node: target_bn, added_nodes: added, removed_nodes: [])
      nil
    end

    # Re-parse everything written since open() as a whole document and make
    # its children the document's (see "Dynamic markup insertion" above).
    def reparse_script_created_input
      parsed = Document.new(nil, backend_doc: Backend.parse(@script_created_input))
      @quirks_mode = parsed.quirks_mode?
      parsed.__internal_mark_scripts_already_started__
      # What the parser builds, not what a script inserts: a doctype and an
      # element go in together, which replaceChildren's checks would refuse.
      removed = @backend_doc.children.to_a
      removed.each { |child| detach_node(child) }
      added = document_insertion_nodes(parsed.child_nodes.to_a)
      added.each { |n| @backend_doc.add_child(n) }
      notify_document_child_list(added: added, removed: removed)
    end

    # "Erase all event listeners and handlers" for the document's
    # shadow-including inclusive descendants and, for a window's document, the
    # window. Only nodes that have a wrapper can hold listeners.
    def erase_all_event_listeners_and_handlers
      targets = [self]
      collect_listener_targets(@backend_doc, targets)
      targets << @default_view if @default_view
      targets.each { |t| t.__internal_erase_event_listeners_and_handlers__ if t.respond_to?(:__internal_erase_event_listeners_and_handlers__) }
    end

    def collect_listener_targets(root_bn, targets)
      Internal::NodeTraversal.subtree_nodes(root_bn).each do |bn|
        wrapper = @node_wrapper_cache.peek(bn)
        next unless wrapper

        targets << wrapper unless wrapper.equal?(self)
        shadow = wrapper.respond_to?(:__internal_shadow_root__) ? wrapper.__internal_shadow_root__ : nil
        next unless shadow

        targets << shadow
        collect_listener_targets(shadow.__dommy_backend_node__, targets) if shadow.__dommy_backend_node__
      end
    end

    # document.open(url, name, features) is window.open; it needs a fully
    # active document (one with a window, here).
    def open_window(args)
      raise DOMException::InvalidAccessError, "the document is not fully active" unless @default_view

      @default_view.__js_call__("open", args)
    end

    private :document_write, :boot_script_running?, :document_open_steps, :boot_script_write,
            :reparse_script_created_input, :erase_all_event_listeners_and_handlers,
            :collect_listener_targets, :open_window

    # Unlink a backend node from its parent and queue a childList removal record
    # capturing the node's position (previous/next sibling) BEFORE the unlink, so
    # the record's previousSibling/nextSibling are correct (the coordinator can't
    # recover them once the node is detached). Used by every remove path.
    def remove_node_with_notify(node)
      parent = node.parent
      return unless parent

      prev_w = node.previous_sibling && wrap_node(node.previous_sibling)
      next_w = node.next_sibling && wrap_node(node.next_sibling)
      detach_node(node)
      notify_child_list_mutation(
        target_node: parent,
        added_nodes: [],
        removed_nodes: [node],
        previous_sibling: prev_w,
        next_sibling: next_w
      )
    end

    # --- Live ranges -------------------------------------------------
    # Ranges are live: a DOM mutation moves their boundary points so they keep
    # designating the same content. They are held weakly, so a range the caller
    # drops is collected rather than pinned for the document's lifetime.




    # WHATWG "removing steps" for live ranges. Must run while `backend_node` is
    # still attached, since the rules are expressed in terms of the position it
    # is about to vacate.
    def __internal_ranges_will_remove__(backend_node)
      return unless live_ranges?

      parent = backend_node.parent
      return unless parent

      removed = wrap_node(backend_node)
      parent_wrapper = wrap_node(parent)
      affected = live_ranges_where { |r| r.__internal_affected_by_removal__(removed, parent_wrapper) }
      return if affected.empty?

      index = child_index_of_wrapper(parent_wrapper, removed)
      return unless index

      affected.each { |r| r.__internal_apply_remove__(removed, parent_wrapper, index) }
    end



    # Node.normalize() on the document: every Text run in the tree.
    def normalize
      __internal_normalize__(@backend_doc)
    end

    # Node#normalize — merge each run of adjacent exclusive Text descendants
    # into its first node (preserving that node's identity, so a JS reference
    # to it survives) and drop empty Text nodes. Recurses the whole subtree,
    # so it serves Element, DocumentFragment, ShadowRoot and the Document alike.
    #
    # A run is merged one sibling at a time: append the sibling's data to the
    # survivor (a characterData record), hand its live range boundaries over,
    # remove it (a childList record), then the next. Read literally, the spec
    # concatenates every sibling's data first (steps 3-4, one "replace data")
    # and removes them afterwards (step 7), which would queue ONE
    # characterData record per run. Every shipping engine merges pairwise
    # instead — Blink, WebCore and Gecko all answer [characterData, childList,
    # characterData, childList, …] for a run of four text nodes, confirmed by
    # running the same script in Chromium 141, WebKitGTK 2.52.6 and Firefox —
    # and the WPT suite fixes only the childList side, so the records follow
    # the engines. The tree and every live range boundary end up exactly where
    # the spec's steps put them: a boundary in a later sibling (or on the
    # parent, pointing at one) is shifted down by each earlier removal and
    # then handed over at the survivor's length of that moment, which is the
    # same offset the batch steps compute up front.
    # https://github.com/takahashim/dommy/issues/24
    def __internal_normalize__(root)
      text_nodes = []
      root.traverse { |node| text_nodes << node if node.text? }

      text_nodes.each do |node|
        next unless node.parent # already removed as part of an earlier run

        if node.content.to_s.empty?
          remove_node_with_notify(node)
          next
        end

        sib = node.next
        while sib&.text?
          following = sib.next
          data = sib.content.to_s
          # The offset the sibling's data lands at inside the survivor — the
          # length of what it already holds, measured before the append.
          length = wrap_node(node).length
          # An empty sibling has nothing to append: the engines skip the data
          # step for it (Gecko checks the length, Blink and WebCore behave the
          # same), so it is removed without a characterData record. Its range
          # boundaries still move to the survivor's join.
          unless data.empty?
            old = node.content.to_s
            node.content = old + data
            notify_character_data_mutation(target_node: node, old_value: old)
          end
          # WHATWG normalize() step 6: the merged-away sibling hands its live
          # range boundaries to the survivor at that offset BEFORE it is
          # removed, or the plain removing steps would strand them on the
          # parent.
          __internal_ranges_normalize_merge__(node, sib, length)
          remove_node_with_notify(sib)
          sib = following
        end
      end

      nil
    end

    def __internal_ranges_replaced_data__(node, offset, count, new_length)
      return unless live_ranges?

      __internal_each_live_range__ { |r| r.__internal_apply_replace_data__(node, offset, count, new_length) }
    end




    # Run the "NodeIterator pre-removing steps" for every live iterator before
    # `backend_node` is detached, so referenceNode/pointerBeforeReferenceNode
    # stay valid. `backend_node` must still be attached (tree intact) here.
    def run_node_iterator_pre_remove(backend_node)
      return unless node_iterators?

      removed = wrap_node(backend_node)
      @node_iterators.each_key { |iter| iter.pre_remove(removed) }
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
      @node_factory.create_element(name)
    end

    def create_text_node(text)
      # WebIDL DOMString: JS null coerces to "null" (undefined -> "undefined").
      @node_factory.create_text_node(text.nil? ? "null" : text)
    end

    def query_selector(selector)
      @node_wrapper_cache.query_selector(selector)
    end

    def query_selector_all(selector)
      @node_wrapper_cache.query_selector_all(selector)
    end

    # `document.styleSheets` — the CSSStyleSheet of each <style> and
    # <link rel=stylesheet> in document order (CSSOM). [SameObject], live, and a
    # StyleSheetList (an indexed getter with no iterable<>, so no pair methods).
    def style_sheets
      @style_sheets ||= StyleSheetList.new do
        query_selector_all("style, link").filter_map do |element|
          element.sheet if element.respond_to?(:sheet)
        end
      end
    end

    def get_element_by_id(id)
      # WebIDL DOMString: a null argument coerces to "null" (so it can match an
      # element with id="null"); undefined already stringifies to "undefined".
      @node_wrapper_cache.get_element_by_id(id.nil? ? "null" : id)
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

    def migrate_xml_template_descendants(root)
      @template_content_registry.migrate_xml_descendants(root)
    end


    private

    # HTML "is a registrable domain suffix of or is equal to" (a single label
    # stands in for the public suffix; see #domain=).
    def registrable_domain_suffix_or_equal?(suffix_string, original_host)
      return false if suffix_string.empty?

      suffix = Internal::UrlParser.parse("http://#{suffix_string}/").host.to_s
      return true if suffix == original_host
      return false if ip_host?(suffix) || ip_host?(original_host)
      return false unless original_host.end_with?(".#{suffix}")
      # The suffix may not itself be a public suffix.
      return false unless suffix.include?(".")

      true
    rescue Internal::UrlParser::Failure
      false
    end

    def ip_host?(host)
      host.start_with?("[") || host.match?(/\A\d+\.\d+\.\d+\.\d+\z/)
    end


    def creator_base_url
      @creator_base_url if @creator_base_url && FALLBACK_BASE_URLS.include?(url)
    end

    # importNode is a clone, so the HTML cloning steps run for it as they do
    # for cloneNode (#__internal_apply_cloning_steps__): the live state Dommy
    # keeps on a wrapper — an input's dirty value, a script's "already
    # started" — is copied onto the new node. The originals' wrappers belong
    # to the source document, so they are looked up there.
    def apply_imported_cloning_steps(src_root, copy_root, deep, source_document)
      return unless source_document.respond_to?(:__internal_peek_wrapper__)

      src_nodes = deep ? Internal::NodeTraversal.subtree_nodes(src_root) : [src_root]
      copy_nodes = deep ? Internal::NodeTraversal.subtree_nodes(copy_root) : [copy_root]
      return unless src_nodes.length == copy_nodes.length

      src_nodes.zip(copy_nodes).each do |orig, copy|
        state = source_document.__internal_peek_wrapper__(orig)&.then { |w| w.respond_to?(:__internal_cloning_state__) && w.__internal_cloning_state__ }
        next unless state

        wrapper = wrap_node(copy)
        wrapper.__internal_apply_cloning_state__(state) if wrapper.respond_to?(:__internal_apply_cloning_state__)
      end
    end

    def node_adopter
      @node_adopter ||= Internal::NodeAdopter.new(self)
    end

    def shadow_including_elements(root, list = [])
      elements = root.element? ? [root] : []
      elements.concat(root.css("*").to_a)
      elements.each do |element|
        list << element
        shadow = @shadow_registry.find_for_host(element)
        shadow_including_elements(shadow.__dommy_backend_node__, list) if shadow
      end
      list
    end

    # "The html element": the document element when it is an HTML <html>.
    def html_element
      root = document_element
      root if root.is_a?(HTMLElement) && root.local_name == "html"
    end

    # An element is a named element with the name `name` when it is one of the
    # exposed kinds and either carries that `name`, or is an object with that
    # `id`, or is an img whose id it is and which also has a non-empty name.
    def named_element?(node, name)
      return false if name.empty?
      return false unless %w[embed form iframe img object].include?(node.name.to_s.downcase)
      own_name = Backend.no_namespace_attribute_value(node, "name")
      return true if own_name == name
      return true if node.name.to_s.casecmp?("object") && Backend.no_namespace_attribute_value(node, "id") == name

      node.name.to_s.casecmp?("img") && Backend.no_namespace_attribute_value(node, "id") == name && !own_name.to_s.empty?
    end

    # Elements the document's named getter exposes, in tree order.
    def named_getter_nodes
      @backend_doc.css("embed, form, iframe, img, object")
    end

    def document_named_property_nodes(name)
      named_getter_nodes.select { |node| named_element?(node, name) }.map { |node| wrap_node(node) }.compact
    end

    # Build a Nokogiri copy of the given node inside our @backend_doc.
    # `deep: true` recurses into children. Used by importNode and
    # adoptNode for cross-document transfer.
    def clone_into_doc(source, deep, source_document = self)
      copy = clone_single_node_into_doc(source, source_document)

      return copy unless deep

      # A <template>'s contents live in a separate content fragment, not its
      # child list, so the pass over `children` misses them. It still runs: an
      # XML document's <template> keeps its children in the child list.
      clone_template_content(source, copy, source_document) if @template_content_registry.template_node?(source)
      source.children.each do |child|
        copy.add_child(clone_into_doc(child, true, source_document))
      end

      copy
    end

    # "Clone a single node" (§4.4): the copy implements the SAME interface as
    # the original — a ProcessingInstruction clones to one, not to the comment
    # its serialization looks like — and carries the same data. An element's
    # copy keeps its name, namespace, prefix and attributes as the backend
    # holds them; children are the caller's business.
    def clone_single_node_into_doc(source, source_document)
      if source.element?
        Backend.import_element(source, @backend_doc)
      elsif source.is_a?(Backend.cdata_class)
        # CDATA is a Text subtype in the backend, so ask about it first.
        Backend.create_cdata(source.content, @backend_doc)
      elsif source.text?
        Backend.create_text(source.content, @backend_doc)
      elsif source.is_a?(Backend.comment_class)
        Backend.create_comment(source.content, @backend_doc)
      elsif source.is_a?(Backend.processing_instruction_class)
        Backend.create_processing_instruction(source.target, source.content, @backend_doc)
      elsif source.is_a?(Backend.document_fragment_class)
        # A DocumentFragment clones to a fragment (its children are appended by
        # the deep pass), NOT to its first child — `importNode(<template>
        # .content, true)` must return a fragment so `.firstElementChild` works
        # (Vue/Alpine x-for clone template content this way). Built via the
        # document's own `fragment` (as TemplateContentRegistry does) rather than
        # `document_fragment_class.new`, so it works on backends whose fragment
        # class isn't directly instantiable (Makiri).
        Parser.fragment("", owner_doc: @backend_doc)
      elsif source.is_a?(Backend.document_type_class)
        wrapper = source_document.wrap_node(source)
        Backend.create_document_type(wrapper.name, wrapper.public_id, wrapper.system_id, @backend_doc)
      else
        Backend.create_text("", @backend_doc)
      end
    end

    # An element's copy is the backend's own, which keeps its name and every
    # attribute's qualified name exactly (a null-namespace `A:B` on an HTML
    # element stays `A:B`, where the DOM's setAttribute would lower-case it).
    # Only a createElementNS name the backend node does not carry lives on the
    # original's wrapper, so the copy's wrapper is given the same metadata.
    # HTML's cloning steps for a <template>: a deep copy of each of the
    # source's contents, appended to the copy's contents.
    def clone_template_content(source, copy, source_document = self)
      content_nodes = source_document.__internal_template_registry__.content_nodes(source)
      return if content_nodes.empty?

      frag = @template_content_registry.contents(copy)
      content_nodes.each { |n| frag.add_child(clone_into_doc(n, true, source_document)) }
    end

    # The document's element child, as a backend node, or nil. The backend's
    # `root` is that element in the ordinary case, but once the element it
    # held is gone it answers the doctype, even when another element has been
    # appended since — so look past it.
    def backend_document_element
      root = @backend_doc.root
      root&.element? ? root : @backend_doc.children.find(&:element?)
    end

    # The first child of the html element — the document element, when it is
    # `html` in the HTML namespace — that is an HTML element named one of
    # `names`, as a backend node; HTML defines both the head and the body
    # element this way. Only the match is wrapped.
    def html_element_child(names)
      root = backend_document_element
      return nil unless root && root.local_name == "html" && Backend.namespace_uri(root) == Internal::Namespaces::HTML

      root.element_children.find { |c| names.include?(c.local_name) && Backend.namespace_uri(c) == Internal::Namespaces::HTML }
    end

    def body_or_frameset?(node)
      node.is_a?(Element) && %w[body frameset].include?(node.local_name) &&
        node.namespace_uri == Internal::Namespaces::HTML
    end

    # document.title's getter (HTML §3.1.3): the child text content of the
    # SVG `title` child of an SVG `svg` document element, else of the title
    # element, stripped and collapsed of ASCII whitespace. ASCII whitespace is
    # exactly tab/LF/FF/CR/space — NOT Ruby's String#strip set, which also
    # removes U+000B (vertical tab) and must be left intact.
    def read_title
      root = backend_document_element
      title = svg_root?(root) ? svg_title_child(root) : html_title_element
      return "" unless title

      Backend.child_text_content(title).gsub(/[\t\n\f\r ]+/, " ").gsub(/\A[\t\n\f\r ]+|[\t\n\f\r ]+\z/, "")
    end

    # document.title's setter: string-replace-all in the SVG title (made the
    # document element's first child when missing), or in the title element
    # (appended to the head element when missing, unless there is no head
    # either). A document element in any other namespace takes no title.
    def write_title(value)
      root = backend_document_element
      if svg_root?(root)
        title = svg_title_child(root)
        title = insert_title(root, Internal::Namespaces::SVG, before: root.children.first) unless title
      elsif root && Backend.namespace_uri(root) == Internal::Namespaces::HTML
        title = html_title_element
        unless title
          head = html_element_child(%w[head])
          return unless head

          title = insert_title(head, Internal::Namespaces::HTML)
        end
      else
        return
      end
      wrap_node(title).text_content = value
    end

    # The title element: the first HTML `title` in the document, in tree order.
    # Matched by namespace and local name: an XML document's `css("title")`
    # does not find an HTML-namespace title, so there the tree is walked.
    def html_title_element
      candidates = html_document? ? @backend_doc.css("title") : Internal::NodeTraversal.subtree_nodes(@backend_doc)
      candidates.find do |node|
        node.element? && node.local_name == "title" && Backend.namespace_uri(node) == Internal::Namespaces::HTML
      end
    end

    def svg_root?(root)
      root && root.local_name == "svg" && Backend.namespace_uri(root) == Internal::Namespaces::SVG
    end

    def svg_title_child(root)
      root.element_children.find { |c| c.local_name == "title" && Backend.namespace_uri(c) == Internal::Namespaces::SVG }
    end

    # A new `title` in `namespace`, inserted into `parent` before `before`
    # (appended when nil), as a backend node.
    def insert_title(parent, namespace, before: nil)
      title = create_element_ns(namespace, "title")
      wrap_node(parent).insert_before(title, before && wrap_node(before))
      title.__dommy_backend_node__
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
