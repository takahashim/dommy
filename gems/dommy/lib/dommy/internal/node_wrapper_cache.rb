# frozen_string_literal: true

module Dommy
  module Internal
    # Manages DOM node identity via wrapper caching.
    # Ensures that wrap_node(nokogiri_node) always returns the same Ruby object.
    # Separates identity/caching management from Document's public DOM API.
    class NodeWrapperCache
      # Distinguishes "no namespace argument given" (derive from the backend /
      # document) from an explicit nil namespace passed by createElementNS.
      NAMESPACE_UNSET = Object.new.freeze

      # Cap on distinct cached selectors before the query cache is cleared
      # wholesale — a backstop against a page that generates unbounded unique
      # selector strings; real pages reuse a small set (tens).
      QUERY_CACHE_CAP = 512

      def initialize(document)
        @document = document
        @wrappers = {}
        # Memoizes document-rooted CSS query results within a DOM generation.
        # querySelector(All) over a large tree is a full descendant walk, yet a
        # heavy page issues the SAME selector hundreds of times between mutations
        # (measured ~87% repeats on a real site). `Document#style_generation`
        # bumps on every childList / attribute / characterData mutation — and on
        # focus / active-element changes too, so `:focus`-dependent selectors are
        # invalidated correctly — so a result tagged with the generation it was
        # computed in stays valid until the next mutation, then is recomputed
        # lazily. Keyed by [kind, selector] => [generation, value].
        @query_cache = {}
      end

      # Returns the wrapped node, creating and caching if needed.
      # Maintains DOM identity across repeated traversals.
      def wrap(node)
        return nil unless node

        key = identity_key(node)
        cached = @wrappers[key]
        # A hit is only trustworthy if the cached wrapper still describes the
        # SAME kind of node as the one now at this identity key. The key is a
        # backend pointer/object_id, and a backend MAY recycle a freed node's
        # identity (Nokogiri reuses object_ids; Makiri reuses the lxb pointer of
        # a *transient* node — e.g. a throwaway fragment parsed by
        # `Parser.fragment` — once it's GC'd). When that happens the stale entry
        # would hand back a wrapper of the wrong type (observed: a Fragment
        # clone resolving to a cached TextNode). Validate cheaply via nodeType —
        # compared against a static class→type map so we never dereference the
        # cached wrapper's (possibly freed) backend node — and rebuild on a miss.
        return cached if cached && cached_wrapper_live?(cached, node)

        wrapper = build_wrapper_for(node)
        @wrappers[key] = wrapper if wrapper
        wrapper
      end

      # Factory methods

      def create_element(name)
        str = domstring(name)
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid element name: #{str.inspect}" unless str.match?(Namespaces::HTML_NAME)

        # WHATWG createElement: lowercase (ASCII) the name only in an HTML
        # document; the namespace is the HTML namespace for HTML/XHTML documents
        # and null for a non-XHTML XML document. Record the metadata so the
        # element's localName/tagName/namespaceURI getters report it faithfully
        # (in particular case preservation for XML/XHTML).
        if @document.html_document?
          local = str.downcase(:ascii)
          namespace = Element::HTML_NAMESPACE
        else
          local = str
          namespace = @document.content_type == "application/xhtml+xml" ? Element::HTML_NAMESPACE : nil
        end

        wrapper = wrap_node(Backend.create_element(local, @document.backend_doc))
        wrapper.__internal_set_namespace__(namespace, nil, local, local)
        wrapper
      end

      def create_text_node(text)
        wrap_node(Backend.create_text(text.to_s, @document.backend_doc))
      end

      def create_cdata_section(text)
        wrap_node(Backend.create_cdata(text.to_s, @document.backend_doc))
      end

      def create_comment(text)
        wrap_node(Backend.create_comment(text.to_s, @document.backend_doc))
      end

      # WHATWG Document.createProcessingInstruction: the target must be a valid
      # XML Name and the data must not contain the PI close delimiter "?>", else
      # InvalidCharacterError. The result is a real backend-backed PI node.
      def create_processing_instruction(target, data)
        t = domstring(target)
        d = domstring(data)
        raise DOMException::InvalidCharacterError, "invalid processing instruction target: #{t.inspect}" unless t.match?(Namespaces::NAME)
        raise DOMException::InvalidCharacterError, "processing instruction data must not contain '?>'" if d.include?("?>")

        wrap_node(Backend.create_processing_instruction(t, d, @document.backend_doc))
      end

      def create_document_fragment
        wrap_node(@document.backend_doc.fragment(""))
      end

      def create_attribute(name)
        str = domstring(name)
        raise DOMException::InvalidCharacterError, "name must not be empty" if str.empty?
        raise DOMException::InvalidCharacterError, "invalid attribute name: #{str.inspect}" unless str.match?(Namespaces::NAME)

        # WHATWG createAttribute: an HTML document lower-cases the name (an XML
        # document preserves it). Attr.new no longer folds case, so do it here.
        str = str.downcase if @document.html_document?
        Attr.new(str)
      end

      def create_attribute_ns(namespace_uri, qualified_name)
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name)
        Attr.new(qualified_name, namespace_uri: ns, prefix: prefix, local_name: local)
      end

      def create_element_ns(namespace_uri, qualified_name)
        # WHATWG "validate and extract": QName-validate the qualifiedName
        # (InvalidCharacterError) and apply the prefix/namespace rules
        # (NamespaceError), then build the element with its prefix bound.
        # namespace is nullable (undefined → null); qualifiedName is a plain
        # DOMString (undefined → "undefined", null → "null").
        namespace_uri = nil if namespace_uri.equal?(Bridge::UNDEFINED)
        qualified_name = domstring(qualified_name)
        ns, prefix, local = Namespaces.validate_and_extract(namespace_uri, qualified_name, context: :element)

        # An XML backend rejects some DOM-valid qualified names (an invalid char
        # in the local part, which DOM permits): the loose creator builds them
        # verbatim. A genuinely invalid name it (or the strict path) rejects with
        # an ArgumentError becomes an InvalidCharacterError, per DOM.
        el =
          begin
            Backend.create_element_loose(qualified_name, prefix, local, ns, @document.backend_doc) ||
              Backend.create_element(qualified_name, @document.backend_doc)
          rescue ArgumentError
            raise DOMException::InvalidCharacterError, "'#{qualified_name}' is not a valid element name"
          end
        Backend.add_namespace_definition(el, prefix, ns) if ns

        wrapper = build_element_wrapper(el, namespace: ns, local_name: local)
        wrapper.__internal_set_namespace__(ns, prefix, local, qualified_name)
        wrapper
      end

      # Query methods

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

        # getElementById matches the `id` attribute literally — it is NOT a CSS
        # selector, so an id with selector-special characters (e.g. React's
        # `useId` values like `:rjm:`) is valid and must still resolve. Escape it
        # to a valid id-selector ident before handing it to the backend's CSS
        # engine (a raw "##{id}" would be an invalid selector and raise).
        wrap(@document.backend_doc.at_css("##{Dommy::CSSNamespace.escape(id)}"))
      end

      def get_elements_by_tag_name(name)
        n = name.to_s.downcase
        doc = @document.backend_doc
        cache = self
        if n == "*"
          HTMLCollection.new { doc.css("*").map { |x| cache.wrap(x) }.compact }
        else
          HTMLCollection.new { doc.css(n).map { |x| cache.wrap(x) }.compact }
        end
      end

      def get_elements_by_name(name)
        doc = @document.backend_doc
        cache = self
        key = name.to_s
        HTMLCollection.new do
          doc.css("[name='#{key}']").map { |x| cache.wrap(x) }.compact
        end
      end

      def get_elements_by_class_name(name)
        tokens = name.to_s.split(/\s+/).reject(&:empty?)
        doc = @document.backend_doc
        cache = self
        HTMLCollection.new do
          next [] if tokens.empty?

          selector = tokens.map { |t| ".#{t}" }.join("")
          doc.css(selector).map { |n| cache.wrap(n) }.compact
        end
      end

      # Clear cached wrapper (used by customElements.define for upgrades)
      def reset_wrapper(nokogiri_node)
        @wrappers.delete(identity_key(nokogiri_node))
      end

      # Register an externally-built wrapper. Used by
      # Document#adopt_node when migrating a wrapper from another
      # document so the existing Ruby object survives the move
      # rather than being replaced by a freshly-built one.
      def register(nokogiri_node, wrapper)
        @wrappers[identity_key(nokogiri_node)] = wrapper
      end

      private

      # Whether a cached wrapper still describes the node now at its identity
      # key. A pure class→nodeType lookup: it must NOT dereference the wrapper's
      # backend node, which may be a freed pointer after identity recycling.
      # Unknown/exotic wrappers (Document, ShadowRoot, …) aren't produced by the
      # fragment-parse paths that recycle identities, so we trust those entries
      # rather than rebuild.
      def cached_wrapper_live?(wrapper, node)
        return true unless node.respond_to?(:node_type)

        expected =
          case wrapper
          when Fragment then 11
          when CDATASectionNode then 4 # subclass of TextNode — test first
          when TextNode then 3
          when CommentNode then 8
          when ProcessingInstructionNode then 7
          else
            return true unless wrapper.is_a?(Element)

            1
          end
        expected == node.node_type
      end

      # The cached value for [kind, selector] if it was computed in the current
      # DOM generation, else nil (a miss, or a stale entry the caller recomputes).
      def query_cache_get(kind, selector)
        entry = @query_cache[[kind, selector]]
        return nil unless entry && entry[0] == @document.style_generation

        entry[1]
      end

      # Store `value` for [kind, selector] tagged with the current generation,
      # clearing the cache wholesale if it has grown past the cap.
      def query_cache_set(kind, selector, value)
        @query_cache.clear if @query_cache.size >= QUERY_CACHE_CAP
        @query_cache[[kind, selector]] = [@document.style_generation, value]
      end

      # DOM identity key for a backend node, delegated to the backend since
      # the right key differs: Nokogiri reuses one Ruby wrapper per C node
      # (object_id stable) and may recycle a freed node's pointer, so it keys
      # on object_id; Makiri mints fresh wrappers but never frees nodes, so it
      # keys on the stable node pointer (pointer_id).
      def identity_key(node)
        Backend.identity_key(node)
      end

      # WebIDL DOMString coercion for a name/qualifiedName argument: JS
      # `undefined` → "undefined", JS `null` (Ruby nil) → "null", else #to_s.
      def domstring(value)
        return "undefined" if value.equal?(Bridge::UNDEFINED)
        return "null" if value.nil?

        value.to_s
      end

      def wrap_node(node)
        wrap(node)
      end

      def build_wrapper_for(node)
        case node
        when Backend.element_class
          build_element_wrapper(node)
        when ->(n) { Backend.cdata_class && n.is_a?(Backend.cdata_class) }
          # CDATA is a Text subtype in the backend, so match it before text_class.
          CDATASectionNode.new(@document, node)
        when Backend.text_class
          TextNode.new(@document, node)
        when Backend.comment_class
          CommentNode.new(@document, node)
        when Backend.processing_instruction_class
          ProcessingInstructionNode.new(@document, node)
        when Backend.document_fragment_class
          Fragment.new(@document, node)
        end
      end

      # `namespace`/`local_name` let a caller that already knows the element's
      # namespace and local name (e.g. createElementNS, which preserves case and
      # carries a prefix the backend node name would otherwise fold in) route the
      # wrapper class directly, rather than re-deriving it from the backend.
      #
      # When `namespace` is not supplied we derive it: the backend reports the
      # null namespace for ordinary HTML elements, so in an HTML document an
      # otherwise-namespaceless element is treated as HTML-namespaced (preserving
      # HTML* interface routing); a non-HTML document leaves it null (generic
      # Element). An explicit `namespace:` (including nil from createElementNS)
      # is honored verbatim.
      def build_element_wrapper(node, namespace: NAMESPACE_UNSET, local_name: nil)
        ns =
          if namespace.equal?(NAMESPACE_UNSET)
            Backend.namespace_of(node)&.href || (@document.html_document? ? Element::HTML_NAMESPACE : nil)
          else
            namespace
          end
        # A JS-defined custom element (`customElements.define(name, classExpr)`
        # from page script) registers its JS constructor — a HostCallback — not a
        # Ruby class, so we cannot `.new(@document, node)` it. Wrap such a node as
        # its plain built-in element instead (its server-rendered light-DOM
        # content still displays; the JS upgrade is simply not run). Only a Ruby
        # class definition routes a custom Ruby wrapper + #construct.
        custom_klass = custom_element_class_for(node.name)
        ruby_custom = custom_klass if custom_klass.is_a?(::Class)
        klass = ruby_custom || Dommy.element_class_for(local_name || node.name, ns)
        instance = klass.new(@document, node)

        @wrappers[identity_key(node)] = instance

        if ruby_custom && instance.respond_to?(:construct)
          begin
            instance.construct
          rescue StandardError
            nil
          end
        end

        instance
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
