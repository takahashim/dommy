# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG DOM "equals" / Node.isEqualNode (https://dom.spec.whatwg.org/#concept-node-equals).
    # Operates on Dommy node wrappers through their bridge-facing accessors
    # (__js_get__ for the per-type data, #child_nodes / #attributes for the
    # structure), so it works uniformly across the heterogeneous node classes.
    module NodeEquality
      module_function

      def equal?(a, b)
        return false if b.nil?

        type = prop(a, "nodeType")
        return false unless type == prop(b, "nodeType")
        return false unless data_equal?(a, b, type)

        kids_a = children(a)
        kids_b = children(b)
        return false unless kids_a.length == kids_b.length

        kids_a.each_index { |i| return false unless equal?(kids_a[i], kids_b[i]) }
        true
      end

      # Per-type "these two nodes have equal own properties" (children compared
      # separately by #equal?).
      def data_equal?(a, b, type)
        case type
        when Node::ELEMENT_NODE
          prop(a, "namespaceURI") == prop(b, "namespaceURI") &&
            prop(a, "prefix") == prop(b, "prefix") &&
            prop(a, "localName") == prop(b, "localName") &&
            attributes_equal?(a, b)
        when Node::DOCUMENT_TYPE_NODE
          prop(a, "nodeName") == prop(b, "nodeName") &&
            prop(a, "publicId") == prop(b, "publicId") &&
            prop(a, "systemId") == prop(b, "systemId")
        when Node::PROCESSING_INSTRUCTION_NODE
          prop(a, "target") == prop(b, "target") && prop(a, "data") == prop(b, "data")
        when Node::TEXT_NODE, Node::CDATA_SECTION_NODE, Node::COMMENT_NODE
          prop(a, "data") == prop(b, "data")
        when Node::ATTRIBUTE_NODE
          prop(a, "namespaceURI") == prop(b, "namespaceURI") &&
            prop(a, "localName") == prop(b, "localName") &&
            prop(a, "value") == prop(b, "value")
        else
          # Document / DocumentFragment carry no own properties to compare.
          true
        end
      end

      # Equal attribute lists, order-independent (each attribute of A must have
      # a (namespace, localName, value) match in B, and the counts must match).
      def attributes_equal?(a, b)
        attrs_a = attribute_descriptors(a)
        attrs_b = attribute_descriptors(b)
        return false unless attrs_a.length == attrs_b.length

        attrs_a.all? { |x| attrs_b.include?(x) }
      end

      def attribute_descriptors(node)
        return [] unless node.respond_to?(:attributes)

        map = node.attributes
        (0...map.length).map do |i|
          attr = map.item(i)
          [attr.namespace_uri, attr.local_name, attr.value]
        end
      end

      def children(node)
        return [] unless node.respond_to?(:child_nodes)

        list = node.child_nodes
        list.respond_to?(:to_a) ? list.to_a : (0...list.length).map { |i| list.item(i) }
      end

      def prop(node, key)
        node.__js_get__(key)
      end
    end
  end
end
