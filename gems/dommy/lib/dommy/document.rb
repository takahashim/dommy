# frozen_string_literal: true

require "uri"

require_relative "internal/node_wrapper_cache"
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

    # A name createDocumentType refuses. It is otherwise extremely permissive —
    # "1foo", "@foo", "edi:%" and the empty string are all accepted — but a name
    # carrying whitespace or ">" could not be serialized back as a doctype, and
    # is an InvalidCharacterError.
    UNSERIALIZABLE_DOCTYPE_NAME = /[\s>]/

    # A created DocumentType's node document is the implementation's document. When
    # the backend ships a doctype factory (the HTML backend) and accepts the name,
    # the result is a real, node-backed (but detached) DocumentType that can join
    # the tree; otherwise it falls back to a synthetic one — the factory's own
    # (stricter, XML-flavoured) name check is not the DOM rule.
    def create_document_type(qualified_name, public_id, system_id)
      qn = qualified_name.to_s
      if qn.match?(UNSERIALIZABLE_DOCTYPE_NAME)
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
      doc.__internal_ranges_will_insert__(doc.backend_doc, root, 1)
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
    attr_accessor :__css_style_cache__

    def style_generation
      @style_generation || 0
    end

    def dom_generation
      @dom_generation || 0
    end

    # Moves only on childList mutations — the coarsest epoch. Keys memos
    # whose value depends on the element population alone (which elements
    # exist, in what order), like the document's <style>/<link> list: an
    # attribute-triggered cascade rebuild can then skip re-walking for them.
    def tree_generation
      @tree_generation || 0
    end

    def __internal_bump_style_generation__
      @style_generation = style_generation + 1
      nil
    end

    def __internal_bump_dom_generation__
      @dom_generation = dom_generation + 1
      nil
    end

    # A childList mutation: tree shape feeds both selector matching and the
    # rule -> element index, so everything is suspect.
    def __internal_note_tree_mutation__
      @tree_generation = tree_generation + 1
      __internal_bump_dom_generation__
      __internal_bump_style_generation__
    end

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

    # An attribute mutation: selector results are always suspect (any cached
    # query could carry an attribute selector), but the cascade only when the
    # indexed rules read this attribute — or when the attribute belongs to a
    # <style>/<link>, whose media/disabled/rel gate whole sheets.
    def __internal_note_attribute_mutation__(name, target_node)
      __internal_bump_dom_generation__
      __internal_bump_style_generation__ if __internal_style_affected_by_attribute__(name, target_node)
    end

    # A characterData mutation. Text participates in matching only through
    # `:empty` (a text node counts iff its data is non-empty), so nothing is
    # suspect unless the edit flips that emptiness — except text inside a
    # <style>, which IS the stylesheet source.
    def __internal_note_character_data_mutation__(target_node, old_value)
      # Only a Text node's data participates in :empty; a comment/PI edit
      # can't change any match. `target_node` is a backend node, so its data
      # reads through the Nokogiri-compatible #content.
      text = target_node.respond_to?(:node_type) && target_node.node_type == 3
      flipped = text && (old_value.to_s.empty? != target_node.content.to_s.empty?)
      __internal_bump_dom_generation__ if flipped
      if __internal_inside_style_element__(target_node) ||
         (flipped && __internal_style_text_sensitive__)
        __internal_bump_style_generation__
      end
      nil
    end

    # Selector-observable state that lives outside the attribute space
    # (focus, hover, checkedness…): both cache families are suspect.
    def __internal_note_selector_state_change__
      __internal_bump_dom_generation__
      __internal_bump_style_generation__
    end

    # A form control's IDL value changed (typing, `input.value = …`, a form
    # reset). No attribute mutates, yet the value is selector-observable
    # through the validity / range / placeholder pseudo-classes, so the
    # selector epoch always moves — a cached `querySelectorAll(":invalid")`
    # would otherwise survive the very change that flipped it. The cascade
    # follows only when a sheet actually uses one of those pseudo-classes.
    def __internal_note_value_change__
      __internal_bump_dom_generation__
      __internal_bump_style_generation__ if __internal_style_value_sensitive__
      nil
    end

    def __internal_style_value_sensitive__
      index = @__css_style_cache__ && @__css_style_cache__[:index]
      index ? index.value_sensitive? : true
    end

    def __internal_style_affected_by_attribute__(name, target_node)
      owner = target_node.respond_to?(:name) ? target_node.name.to_s.downcase : nil
      return true if owner == "style" || owner == "link"

      index = @__css_style_cache__ && @__css_style_cache__[:index]
      # No RuleIndex yet: the bump is nearly free (at most it drops the
      # author_css?/counters memos), so stay conservative.
      return true unless index

      index.attribute_dependency?(name)
    end

    def __internal_style_text_sensitive__
      index = @__css_style_cache__ && @__css_style_cache__[:index]
      index ? index.text_sensitive? : true
    end

    def __internal_inside_style_element__(node)
      # No <style> in the document -> a text edit can't be sheet source, so
      # skip the ancestor walk. The sheet-element list is memoized per
      # tree_generation (only childList changes it), so a text-editing loop
      # between childList mutations answers this without re-walking.
      return false unless __internal_style_sheet_elements__.any? { |el| el.local_name.to_s.casecmp?("style") }

      current = node.respond_to?(:parent) ? node.parent : nil
      while current
        return true if current.respond_to?(:name) && current.name.to_s.downcase == "style"

        current = current.respond_to?(:parent) ? current.parent : nil
      end
      false
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

      @__sel_idx ||= Internal::SelectorIndex.build(@backend_doc)
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
      # resolve through this.
      root = @backend_doc.root
      return nil unless root&.element?

      wrap_node(root)
    end

    def head
      # The first `head` element child of the document element in the HTML
      # namespace (readonly — assignment is a no-op, see __js_set__). Not just
      # `at_css("head")`, which searches the whole tree and ignores namespace.
      root = document_element
      return nil unless root

      root.child_nodes.to_a.find do |c|
        c.respond_to?(:local_name) && c.local_name == "head" &&
          c.respond_to?(:namespace_uri) && c.namespace_uri == "http://www.w3.org/1999/xhtml"
      end
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
      # a change invalidates cached query results and computed styles.
      __internal_note_selector_state_change__ unless @active_element.equal?(el)
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
      __internal_note_selector_state_change__
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
      # An Attr is a Node but not a backend-tree node: it is copied by rebuilding
      # it here with the same qualified name, namespace, prefix and value, owned
      # by no element (importNode never attaches the copy to anything).
      return import_attribute(node) if node.is_a?(Attr)
      return nil unless node.respond_to?(:__dommy_backend_node__)

      # WebIDL `optional boolean deep = false`: a missing / undefined argument
      # is the default (false / shallow), not a truthy sentinel.
      deep = false if deep.nil? || deep.equal?(Bridge::UNDEFINED)
      source_document = node.respond_to?(:document) ? node.document : self
      copy = clone_into_doc(node.__dommy_backend_node__, deep, source_document)
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

    def node_adopter
      @node_adopter ||= Internal::NodeAdopter.new(self)
    end
    private :node_adopter

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
        # HTML cloning steps for <template>: its content lives in an off-tree
        # fragment the backend's subtree clone never reaches, so a deep clone has
        # to copy it across explicitly (a shallow clone gets an empty template,
        # per spec).
        clone_template_content(orig, copy) if deep && @template_content_registry.has_content?(orig)

        wrapper = @node_wrapper_cache.peek(orig)
        next unless wrapper.respond_to?(:__cloning_state__)

        state = wrapper.__cloning_state__
        next if state.nil?

        @node_wrapper_cache.wrap(copy).__apply_cloning_state__(state)
      end
    end

    # Legacy `document.createEvent("EventName")` factory. Returns an
    # Event subclass instance whose init still has to be called
    # (`event.initEvent(type, bubbles, cancelable)`). Matches the
    # mapping happy-dom and linkedom use.
    def create_event(type_name)
      name = type_name.to_s
      event =
        case name
        when "CustomEvent"
          CustomEvent.new("")
        when "MouseEvent", "MouseEvents"
          MouseEvent.new("")
        when "KeyboardEvent", "KeyboardEvents"
          KeyboardEvent.new("")
        else
          Event.new("")
        end
      # createEvent hands back an *uninitialized* event: it has no type yet and
      # dispatching it before initEvent() is an InvalidStateError.
      event.__internal_mark_uninitialized__
      event
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
      @node_wrapper_cache.create_processing_instruction(target, data)
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
      return node unless node.respond_to?(:__dommy_backend_node__)

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
      bn = move_backend_node(node)
      ref_bn = move_backend_node(child)
      ref_bn = ref_bn.next_sibling if ref_bn && bn && ref_bn == bn
      ensure_document_move_validity!(node, bn, ref_bn)

      old_parent = bn.parent
      old_previous = bn.previous_sibling
      old_next = bn.next_sibling
      detach_node(bn)                                             # steps 10-11, 14
      ref_bn = nil if ref_bn && ref_bn.parent != @backend_doc
      __internal_ranges_will_insert__(@backend_doc, ref_bn, 1)    # step 16
      new_previous = ref_bn ? ref_bn.previous_sibling : @backend_doc.children.to_a.last
      ref_bn ? ref_bn.add_previous_sibling(bn) : @backend_doc.add_child(bn) # step 18
      if old_parent
        notify_child_list_mutation(
          target_node: old_parent, added_nodes: [], removed_nodes: [bn],
          previous_sibling: old_previous && wrap_node(old_previous),
          next_sibling: old_next && wrap_node(old_next)
        )
      end
      notify_document_child_list(added: [bn], previous_sibling: new_previous && wrap_node(new_previous),
                                 next_sibling: ref_bn && wrap_node(ref_bn))
      nil
    end

    # The backend node an argument to `moveBefore` stands for. A Dommy::Document
    # has no `__dommy_backend_node__` of its own, but it is a node the algorithm
    # has to see (step 2 rejects it, step 3 measures its parentage).
    def move_backend_node(value)
      return value.backend_doc if value.is_a?(Dommy::Document)
      return nil unless value.respond_to?(:__dommy_backend_node__)

      value.__dommy_backend_node__
    end

    # "Move" steps 1-6 with a document new parent.
    def ensure_document_move_validity!(node, bn, ref_bn)
      # Step 1 — the same root. A document is its own root, so this says the
      # node must already be somewhere in this document.
      root = bn
      root = root.parent while root.respond_to?(:parent) && root.parent
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
      cross_document = !Backend.moves_nodes_across_documents? &&
        new_child.respond_to?(:document) && !new_child.document.equal?(self)
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
      anchor = after ? @backend_doc.root : @backend_doc.children.first
      __internal_ranges_will_insert__(@backend_doc, anchor, bns.size)
      if after
        anchor ? bns.each { |n| anchor.add_previous_sibling(n) } : bns.each { |n| @backend_doc.add_child(n) }
      else
        anchor ? bns.reverse_each { |n| anchor.add_previous_sibling(n) } : bns.each { |n| @backend_doc.add_child(n) }
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
    def document_insertion_count(args)
      args.sum do |arg|
        if arg.is_a?(Dommy::Fragment) then arg.child_nodes.to_a.size
        elsif arg.respond_to?(:__dommy_backend_node__) then 1
        else 0
        end
      end
    end

    def adopted_backend_node(node)
      return nil unless node.respond_to?(:__dommy_backend_node__)

      if !Backend.moves_nodes_across_documents? && node.respond_to?(:document) && !node.document.equal?(self)
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
      # WebIDL DOMString: JS null coerces to "null" (undefined -> "undefined").
      @node_wrapper_cache.create_comment(text.nil? ? "null" : text)
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
        document_element
      when "title"
        read_title
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
        unless args[1].nil? || args[1].equal?(Bridge::UNDEFINED) || args[1].is_a?(Dommy::Node)
          raise Bridge::TypeError, "The reference child is not a Node."
        end

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
    # it owes, its exclusive accordion group settled), and every select has its
    # list of options settled (a single-select the parser left with no, or
    # several, selected options).
    def __internal_run_parsed_insertion_steps__
      return nil unless @backend_doc.respond_to?(:css)

      elements = @backend_doc.css("details").filter_map { |node| wrap_node(node) }
      HTMLDetailsElement.run_insertion_steps(elements) unless elements.empty?
      @backend_doc.css("select").each { |node| wrap_node(node)&.__internal_settle_selectedness_once__ }
      nil
    end

    # Bind an externally built wrapper to its backend node, so later traversals
    # return the same Ruby object (JS identity) instead of building a new one.
    def __internal_register_wrapper__(node, wrapper)
      @node_wrapper_cache.register(node, wrapper)
      wrapper
    end

    # The wrapper already cached for a backend node, or nil — never builds one.
    def __internal_cached_wrapper__(node)
      @node_wrapper_cache.cached_wrapper(node)
    end

    # Recorded when an element is created outside the HTML namespace or with a
    # prefix. Deep cloning only has to carry that metadata across for a document
    # that has some — which the overwhelming majority never do, so the ordinary
    # `body.cloneNode(true)` keeps walking nothing.
    def __internal_note_namespaced_element__(namespace, prefix)
      return if namespace == Element::HTML_NAMESPACE && prefix.nil?

      @namespaced_elements = true
      nil
    end

    def __internal_namespaced_elements__?
      @namespaced_elements == true
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

    # Queue the childList record for a mutation. The live-range insertion steps
    # are NOT run here: WHATWG puts them at insert step 5, before the nodes are
    # converted and linked, so every insertion site calls
    # __internal_ranges_will_insert__ itself, at that point.
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
    alias queue_child_list_record notify_child_list_mutation

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
      node = ref_bn ? ref_bn.previous : @backend_doc.children.to_a.last
      node && wrap_node(node)
    end

    def notify_document_child_list(added: [], removed: [], previous_sibling: nil, next_sibling: nil)
      notify_child_list_mutation(
        target_node: @backend_doc,
        added_nodes: added,
        removed_nodes: removed,
        previous_sibling: previous_sibling,
        next_sibling: next_sibling
      )
    end

    # The single detach primitive: pre-removing steps, then unlink. Callers that
    # batch several removals into one childList record (replaceChildren,
    # textContent=, replaceChild) use this and queue the record themselves;
    # `remove_node_with_notify` is this plus a per-node record.
    def detach_node(node)
      pre_remove_node(node)
      add_transient_observers_for(node)
      node.unlink
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

    def __internal_register_range__(range)
      @live_ranges ||= ObjectSpace::WeakMap.new
      @live_ranges[range] = true
      nil
    end

    def __internal_each_live_range__
      return if @live_ranges.nil? || @live_ranges.size.zero?

      @live_ranges.each_key { |range| yield range }
    end

    def live_ranges?
      !@live_ranges.nil? && @live_ranges.size.positive?
    end

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

    # WHATWG "insert a node into a parent before a child", step 5 — the
    # live-range offset shift.
    #
    # It runs BEFORE step 7 adopts each node (which removes it from wherever it
    # is now), so `child`'s index, and every boundary it shifts, are measured
    # against the tree as it stands before the insertion begins. Running it
    # afterwards double-counts a boundary that one of those removals has just
    # moved onto `parent`: `parent.insertBefore(second, first)` with a range
    # inside `second` leaves that boundary at `(parent, 1)` per spec, but at
    # `(parent, 2)` if the shift is applied after the move.
    #
    # Appending (a null `child`) shifts nothing: a boundary at the parent's end
    # stays before the new nodes.
    def __internal_ranges_will_insert__(parent_backend_node, ref_backend_node, count)
      return if ref_backend_node.nil? || count.zero?
      return unless live_ranges?

      parent_wrapper = wrap_node(parent_backend_node)
      return unless parent_wrapper.respond_to?(:child_nodes)

      affected = live_ranges_where { |r| r.__internal_anchored_at__(parent_wrapper) }
      return if affected.empty?

      index = child_index_of_wrapper(parent_wrapper, wrap_node(ref_backend_node))
      return unless index

      affected.each { |r| r.__internal_apply_insert__(parent_wrapper, index, count) }
    end

    # WHATWG normalize() steps 6.1-6.4. `current` is a contiguous exclusive Text
    # sibling whose data has just been appended to `node` at `length`; its own
    # boundaries — and a parent-anchored boundary pointing AT it — follow the
    # data into the merged node. Run for every merged sibling before any of them
    # is removed, so the indices still describe the pre-removal tree.
    def __internal_ranges_normalize_merge__(node, current, length)
      return unless live_ranges?

      merged_into = wrap_node(node)
      current_wrapper = wrap_node(current)
      parent = current.parent && wrap_node(current.parent)
      index = parent && child_index_of_wrapper(parent, current_wrapper)
      __internal_each_live_range__ do |range|
        range.__internal_apply_normalize_merge__(merged_into, current_wrapper, length, parent, index)
      end
    end

    def __internal_ranges_replaced_data__(node, offset, count, new_length)
      return unless live_ranges?

      __internal_each_live_range__ { |r| r.__internal_apply_replace_data__(node, offset, count, new_length) }
    end

    def __internal_ranges_split_text__(node, offset, new_node)
      return unless live_ranges?

      parent = node.parent_node
      # Only the parent-anchored rule needs an index, so resolve one lazily.
      index =
        if parent && live_ranges_where { |r| r.__internal_anchored_at__(parent) }.any?
          child_index_of_wrapper(parent, node)
        end
      __internal_each_live_range__ { |r| r.__internal_apply_split__(node, offset, new_node, parent, index) }
    end

    def live_ranges_where
      out = []
      __internal_each_live_range__ { |r| out << r if yield(r) }
      out
    end

    def child_index_of_wrapper(parent_wrapper, child_wrapper)
      return nil unless parent_wrapper.respond_to?(:child_nodes)

      parent_wrapper.child_nodes.to_a.index { |c| c.equal?(child_wrapper) }
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
      @node_wrapper_cache.create_element(name)
    end

    def create_text_node(text)
      # WebIDL DOMString: JS null coerces to "null" (undefined -> "undefined").
      @node_wrapper_cache.create_text_node(text.nil? ? "null" : text)
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

    def has_template_content?(nokogiri_node)
      @template_content_registry.has_content?(nokogiri_node)
    end

    private

    # Build a Nokogiri copy of the given node inside our @backend_doc.
    # `deep: true` recurses into children. Used by importNode and
    # adoptNode for cross-document transfer.
    def clone_into_doc(source, deep, source_document = self)
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
        Parser.fragment("", owner_doc: @backend_doc)
      else
        # Fallback: serialize + reparse via fragment for unusual types.
        fragment = Parser.fragment(source.to_html, owner_doc: @backend_doc)
        fragment.children.first || Backend.create_text("", @backend_doc)
      end

      if source.element? && source.name == "template"
        # A <template>'s contents live in a separate content fragment, not its
        # child list, so the generic deep pass over `children` misses them.
        clone_template_content(source, copy, source_document) if deep
      elsif deep && source.respond_to?(:children)
        source.children.each do |child|
          copy.add_child(clone_into_doc(child, true, source_document))
        end
      end

      copy
    end

    # Clone a <template>'s content into a fragment registered as `copy`'s
    # template content. The source content lives backend-dependently — Makiri
    # keeps it in a native content fragment, Nokogiri keeps it as direct children
    # before migration and in the registry after — so source it from the registry
    # fragment when migrated, else from Backend.template_content_nodes.
    def clone_template_content(source, copy, source_document = self)
      registry = source_document.__internal_template_registry__
      src_frag = registry.raw_fragment_for(source)
      content_nodes = src_frag ? src_frag.children.to_a : Backend.template_content_nodes(source)
      return if content_nodes.empty?

      frag = Parser.fragment("", owner_doc: @backend_doc)
      content_nodes.each { |n| frag.add_child(clone_into_doc(n, true, source_document)) }
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

      title.children.to_a.each { |child| detach_node(child) }
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
