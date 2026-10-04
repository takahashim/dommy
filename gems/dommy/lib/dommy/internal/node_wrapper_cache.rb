# frozen_string_literal: true

require_relative "bounded_cache"
require_relative "literal_lookup"

module Dommy
  module Internal
    # DOM node identity: #wrap answers the same Ruby object for the same
    # backend node, for as long as that node is alive.
    #
    # It also memoizes the document's CSS query results, which are keyed by the
    # same generation the identity table is validated against. Creating nodes is
    # NodeFactory's, and asks this for the wrappers.
    class NodeWrapperCache
      # Cap on distinct cached selectors before the query cache is cleared
      # wholesale — a backstop against a page that generates unbounded unique
      # selector strings; real pages reuse a small set (tens).
      QUERY_CACHE_CAP = 512

      def initialize(document)
        @document = document
        # Keyed by the backend node object itself. Makiri hands out one Ruby
        # object per node for as long as its document lives, and this table
        # holds each key, so a key never stands for another node: no pointer
        # a freed document gave up can collide with a live one here.
        @wrappers = {}.compare_by_identity
        # Memoizes document-rooted CSS query results within a DOM generation.
        # querySelector(All) over a large tree is a full descendant walk, yet a
        # heavy page issues the SAME selector hundreds of times between mutations
        # (measured ~87% repeats on a real site). `Document#dom_generation`
        # bumps on every match-relevant mutation (childList / attributes /
        # emptiness-flipping characterData) — and on focus / active-element
        # changes too, so `:focus`-dependent selectors are invalidated
        # correctly — so a result tagged with the generation it was computed
        # in stays valid until the next mutation, then is recomputed lazily.
        # Keyed by [kind, selector] => [generation, value].
        @query_cache = BoundedCache.new(QUERY_CACHE_CAP)
      end

      # Returns the wrapped node, creating and caching if needed.
      # Maintains DOM identity across repeated traversals.
      def wrap(node)
        return nil unless node

        cached = @wrappers[node]
        return cached if cached

        wrapper = build_wrapper_for(node)
        @wrappers[node] = wrapper if wrapper
        wrapper
      end

      # Factory methods

      def query_selector(selector)
        return nil if selector.nil?

        key = selector.to_s
        hit = query_cache_get(:first, key)
        return hit.first if hit # [result] tuple — distinguishes a cached nil match from a miss

        ast = Internal::SelectorParser.parse!(selector)
        result = Internal::SelectorMatcher.query_first(@document, ast)
        query_cache_set(:first, key, [result])
        result
      end

      def query_selector_all(selector)
        return NodeList.new if selector.nil?

        key = selector.to_s
        hit = query_cache_get(:all, key)
        return NodeList.new(hit) if hit # NodeList.new copies, so the cached array is never aliased

        ast = Internal::SelectorParser.parse!(selector)
        matches = Internal::SelectorMatcher.query(@document, ast)
        query_cache_set(:all, key, matches)
        NodeList.new(matches)
      end

      def get_element_by_id(id)
        return nil if id.nil? || id.to_s.empty?

        wrap(LiteralLookup.element_by_id(@document.backend_doc, id.to_s))
      end

      def get_elements_by_tag_name(name)
        HTMLCollection.elements_by_tag_name(@document.backend_doc, @document, name)
      end

      # A live NodeList, as HTML's getElementsByName returns — not an
      # HTMLCollection, so it has no namedItem.
      def get_elements_by_name(name)
        doc = @document.backend_doc
        cache = self
        key = name.to_s
        LiveNodeList.new do
          LiteralLookup.elements_named(doc, key).map { |x| cache.wrap(x) }.compact
        end
      end

      def get_elements_by_class_name(name)
        tokens = LiteralLookup.class_tokens(name)
        root = @document.backend_doc
        cache = self
        HTMLCollection.new do
          next [] if tokens.empty?

          LiteralLookup.elements_with_classes(@document, root, tokens).map { |n| cache.wrap(n) }.compact
        end
      end

      # Clear cached wrapper (used by customElements.define for upgrades).
      # An upgrade replaces a node's wrapper without mutating the tree, so
      # nothing bumps `dom_generation` and the query cache would keep handing
      # out the wrapper this just retired — a `querySelector` after the upgrade
      # would answer with the element's pre-upgrade self. Drop the memoized
      # results too. Upgrades are rare (a handful per page), so clearing the
      # whole cache costs less than tracking which selectors matched the node.
      def reset_wrapper(nokogiri_node)
        @query_cache.clear
        @wrappers.delete(nokogiri_node)
      end

      # The cached wrapper for `node`, or nil — WITHOUT creating one (unlike
      # #wrap). Used by cross-document adoption to find the live descendant
      # wrappers that must be reseated onto the imported copy.
      def peek(node)
        node && @wrappers[node]
      end

      # Register an externally-built wrapper. Used by
      # Document#adopt_node when migrating a wrapper from another
      # document so the existing Ruby object survives the move
      # rather than being replaced by a freshly-built one.
      def register(nokogiri_node, wrapper)
        @wrappers[nokogiri_node] = wrapper
      end

      # NodeFactory mints the nodes this wraps, so it asks for the wrapper
      # builder directly rather than going through the identity-checked #wrap.
      #
      # The class is the one for the backend node's own namespace — the one
      # Element#namespace_uri reports, so the interface always agrees with it:
      # an XHTML element in an XML document is an HTML element, and a
      # no-namespace element in an HTML document is a plain Element — and its
      # local name (an XML node's name holds its prefix).
      def build_element_wrapper(node)
        ns = Backend.namespace_uri(node)
        # A JS-defined custom element (`customElements.define(name, classExpr)`
        # from page script) registers its JS constructor — a HostCallback — not a
        # Ruby class, so we cannot `.new(@document, node)` it. Wrap such a node as
        # its plain built-in element instead (its server-rendered light-DOM
        # content still displays; the JS upgrade is simply not run). Only a Ruby
        # class definition routes a custom Ruby wrapper + #construct.
        custom_klass = custom_element_class_for(node.name)
        ruby_custom = custom_klass if custom_klass.is_a?(::Class)
        klass = ruby_custom || Dommy.element_class_for(node.local_name, ns)
        instance = klass.new(@document, node)

        @wrappers[node] = instance

        # A custom element's constructor is the page's code, so an exception in
        # it is reported at the window rather than discarded — the wrapper still
        # exists either way, which is what the caller is owed.
        if ruby_custom && instance.respond_to?(:construct)
          begin
            instance.construct
          rescue StandardError => e
            report_construct_exception(e)
          end
        end

        instance
      end
      private

      # The cached value for [kind, selector] if it was computed in the current
      # DOM generation, else nil (a miss, or a stale entry the caller recomputes).
      def query_cache_get(kind, selector)
        entry = @query_cache[[kind, selector]]
        return nil unless entry && entry[0] == @document.dom_generation

        entry[1]
      end

      # Store `value` for [kind, selector] tagged with the generation it was
      # computed in; a later generation makes the entry a miss.
      def query_cache_set(kind, selector, value)
        @query_cache[[kind, selector]] = [@document.dom_generation, value]
      end

      def build_wrapper_for(node)
        case node
        when Backend.document_class
          # The backend document node has no wrapper of its own — map it to the
          # Dommy Document that owns this cache, so a top-level node's parentNode /
          # getRootNode resolves to the document (documentElement.parentNode ===
          # document), matching the DOM tree.
          @document
        when Backend.element_class
          build_element_wrapper(node)
        when Backend.cdata_class
          # CDATA is a Text subtype in the backend, so match it before text_class.
          CDATASectionNode.new(@document, node)
        when Backend.text_class
          TextNode.new(@document, node)
        when Backend.comment_class
          CommentNode.new(@document, node)
        when Backend.processing_instruction_class
          ProcessingInstructionNode.new(@document, node)
        when Backend.document_fragment_class
          # A shadow tree's backing fragment IS its ShadowRoot, so `parentNode`
          # from the top of a shadow tree has to reach the ShadowRoot — a bare
          # Fragment wrapper would have no host and no mode, and the walk out of
          # the tree would dead-end there.
          @document.__internal_shadow_root_for_fragment__(node) || Fragment.new(@document, node)
        when Backend.document_type_class
          DocumentType.new(backend_node: node, document: @document)
        end
      end


      def report_construct_exception(error)
        window = (@document.default_view if @document.respond_to?(:default_view))
        return unless window.respond_to?(:__internal_report_exception__)

        Internal::ExceptionReport.report_at(window, error)
      end

      def custom_element_class_for(tag_name)
        # Custom elements are registered on window, not document.
        # Access via default_view if available.
        default_view = @document.default_view
        default_view&.custom_elements&.get(tag_name)
      end
    end
  end
end
