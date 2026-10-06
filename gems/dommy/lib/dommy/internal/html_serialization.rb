# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's "HTML fragment serialization algorithm" (§13.3), given a node, a
    # boolean serializableShadowRoots and a list shadowRoots — the algorithm
    # behind innerHTML / outerHTML (false, []) and getHTML(options).
    #
    # The backend serializes a tree the way the algorithm does, but it knows
    # nothing of what Dommy keeps beside the tree: shadow roots (a host's
    # shadow tree lives in a fragment of its own) and the "is value" of an
    # element created with `{is}` and no `is` attribute. So the backend's
    # serializer stays the fast path, and only when such a node can be in the
    # subtree is it walked here: once, to find the nodes on a path to one, and
    # then again to write those nodes by hand, every other subtree still
    # going through the backend.
    #
    # Spec: https://html.spec.whatwg.org/multipage/parsing.html#html-fragment-serialisation-algorithm
    class HtmlSerialization
      # "Serializes as void": the void elements, and basefont, bgsound, frame,
      # keygen and param.
      VOID = %w[
        area base br col embed hr img input link meta source track wbr basefont bgsound frame keygen param
      ].to_h { |name| [name, true] }.freeze

      # Elements in these namespaces serialize under their local name; any
      # other under its qualified name.
      LOCAL_NAME_NAMESPACES = [Namespaces::HTML, Namespaces::MATHML, Namespaces::SVG].freeze

      # The children of `node` (an Element's, a DocumentFragment's, a
      # ShadowRoot's, a Document's; a `<template>`'s template contents).
      def self.children(document, node, serializable_shadow_roots: false, shadow_roots: EMPTY)
        new(document, serializable_shadow_roots, shadow_roots).children_of(node)
      end

      EMPTY = [].freeze

      # `node` itself and its subtree, as outerHTML serializes an element:
      # the algorithm run on a parent holding only it.
      def self.node(document, node)
        new(document, false, EMPTY).serialize_node(node)
      end

      # The GetHTMLOptions dictionary: [serializableShadowRoots, shadowRoots],
      # each defaulted (false, []); a shadowRoots entry that is not a
      # ShadowRoot is a TypeError.
      def self.get_html_options(options)
        return [false, []] if options.nil? || options.equal?(Bridge::UNDEFINED)
        raise Bridge::TypeError, "getHTML options must be a dictionary" unless options.is_a?(Hash)

        member = ->(key) { options.key?(key) ? options[key] : options[key.to_sym] }
        serializable = WebIDL.boolean(member.call("serializableShadowRoots"))
        roots = member.call("shadowRoots")
        roots = [] if roots.nil? || roots.equal?(Bridge::UNDEFINED)
        raise Bridge::TypeError, "shadowRoots must be a sequence" unless roots.respond_to?(:to_a) && !roots.is_a?(String) && !roots.is_a?(Hash)

        roots = roots.to_a
        raise Bridge::TypeError, "shadowRoots must hold ShadowRoot objects" unless roots.all? { |root| root.is_a?(ShadowRoot) }

        [serializable, roots]
      end

      def initialize(document, serializable_shadow_roots, shadow_roots)
        @document = document
        @serializable_shadow_roots = serializable_shadow_roots ? true : false
        @shadow_roots = shadow_roots
        @shadows = (@serializable_shadow_roots || !shadow_roots.empty?) && document.__internal_any_shadow_roots__?
        @is_values = document.__internal_any_is_values__?
        @special = nil
      end

      def children_of(node)
        return fast_children(node) unless @shadows || @is_values

        node_bn = backend(node)
        @special = {}
        mark(node_bn)
        return fast_children(node) unless special?(node_bn)

        out = +""
        write_children(node_bn, out)
        out
      end

      def serialize_node(node)
        node_bn = backend(node)
        return node_bn.to_html unless @shadows || @is_values

        @special = {}
        mark(node_bn)
        return node_bn.to_html unless special?(node_bn)

        out = +""
        write_node(node_bn, out)
        out
      end

      private

      def backend(node) = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : node

      def fast_children(node)
        node_bn = backend(node)
        return "" if void?(node_bn)

        contents = template_contents(node_bn)
        return "" if contents == :empty
        return contents.children.map(&:to_html).join if contents
        return node_bn.inner_html if node_bn.element?

        node_bn.children.map(&:to_html).join
      end

      def void?(node_bn)
        node_bn.element? && VOID.key?(node_bn.local_name) && Backend.namespace_uri(node_bn) == Namespaces::HTML
      end

      # The template contents an HTML `<template>` serializes in place of its
      # children, or nil.
      def template_contents(node_bn)
        return nil unless node_bn.element? && node_bn.local_name == "template" &&
                          Backend.namespace_uri(node_bn) == Namespaces::HTML

        @document.__internal_template_registry__.existing_contents(node_bn) || :empty
      end

      def child_nodes(node_bn)
        contents = template_contents(node_bn)
        return [] if contents == :empty
        return contents.children.to_a if contents

        node_bn.children.to_a
      end

      def special?(node_bn) = @special.key?(Backend.identity_key(node_bn))

      # Mark `node_bn` and every node in its subtree (template contents and
      # serialized shadow trees included) that is, or holds, a node the
      # backend cannot serialize. Returns whether `node_bn` is marked.
      def mark(node_bn)
        found = false
        if node_bn.element?
          found = true if unattributed_is_value(node_bn)
          shadow = included_shadow_root(node_bn)
          if shadow
            found = true
            mark(shadow.__dommy_backend_node__)
          end
        end
        child_nodes(node_bn).each { |child| found = true if child.element? && mark(child) }
        @special[Backend.identity_key(node_bn)] = true if found
        found
      end

      # The element's is value when it has no `is` attribute to carry it.
      def unattributed_is_value(node_bn)
        return nil unless @is_values

        wrapper = @document.__internal_peek_wrapper__(node_bn)
        return nil unless wrapper.respond_to?(:__internal_is_value__)

        value = wrapper.__internal_is_value__
        value unless value.nil? || Backend.has_attribute_ns?(node_bn, nil, "is")
      end

      # The host's shadow root, when this run serializes it:
      # serializableShadowRoots and a serializable root, or a root listed in
      # shadowRoots.
      def included_shadow_root(node_bn)
        return nil unless @shadows

        shadow = @document.__internal_shadow_root_for_host__(node_bn)
        return nil unless shadow
        return shadow if @serializable_shadow_roots && shadow.serializable
        return shadow if @shadow_roots.any? { |root| root.equal?(shadow) }

        nil
      end

      def write_children(node_bn, out)
        return if void?(node_bn)

        if node_bn.element? && (shadow = included_shadow_root(node_bn))
          write_shadow_root(shadow, out)
        end
        child_nodes(node_bn).each do |child|
          if child.element? && special?(child)
            write_node(child, out)
          else
            out << child.to_html
          end
        end
      end

      def write_node(node_bn, out)
        return out << node_bn.to_html unless node_bn.element? && special?(node_bn)

        tag = tag_name(node_bn)
        out << "<" << tag
        if (is_value = unattributed_is_value(node_bn))
          out << ' is="' << escape(is_value, attribute: true) << '"'
        end
        Backend.attribute_nodes(node_bn).each do |attr|
          info = Backend.attribute_ns_info(attr)
          out << " " << serialized_attribute_name(info) << '="' << escape(info[:value].to_s, attribute: true) << '"'
        end
        out << ">"
        return if void?(node_bn)

        write_children(node_bn, out)
        out << "</" << tag << ">"
      end

      def write_shadow_root(shadow, out)
        out << '<template shadowrootmode="' << (shadow.mode == "open" ? "open" : "closed") << '"'
        out << ' shadowrootdelegatesfocus=""' if shadow.delegates_focus
        out << ' shadowrootserializable=""' if shadow.serializable
        out << ' shadowrootslotassignment="manual"' if shadow.slot_assignment == "manual"
        out << ' shadowrootclonable=""' if shadow.clonable
        out << ' shadowrootcustomelementregistry=""' if append_registry_attribute?(shadow)
        out << ">"
        write_children(shadow.__dommy_backend_node__, out)
        out << "</template>"
      end

      # shouldAppendRegistryAttribute: false when the shadow root and its
      # document both have no registry, or both a global one.
      def append_registry_attribute?(shadow)
        document_registry = CustomElementRegistry.for_document(shadow.document)
        shadow_registry = shadow.__internal_custom_element_registry__
        return false if document_registry.nil? && shadow_registry.nil?
        return false if document_registry && !document_registry.scoped? && shadow_registry && !shadow_registry.scoped?

        true
      end

      def tag_name(node_bn)
        return node_bn.local_name if LOCAL_NAME_NAMESPACES.include?(Backend.namespace_uri(node_bn))

        prefix = Backend.prefix(node_bn)
        prefix.nil? || prefix.empty? ? node_bn.local_name : "#{prefix}:#{node_bn.local_name}"
      end

      def serialized_attribute_name(info)
        case info[:namespace_uri]
        when nil, "" then info[:local_name]
        when Namespaces::XML then "xml:#{info[:local_name]}"
        when Namespaces::XMLNS then info[:local_name] == "xmlns" ? "xmlns" : "xmlns:#{info[:local_name]}"
        when Namespaces::XLINK then "xlink:#{info[:local_name]}"
        else info[:qualified_name]
        end
      end

      ESCAPES = {"&" => "&amp;", " " => "&nbsp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;"}.freeze

      # "Escaping a string": &, U+00A0, < and > always, " in attribute mode.
      def escape(string, attribute: false)
        string.gsub(attribute ? /[& <>"]/ : /[& <>]/, ESCAPES)
      end
    end
  end
end
