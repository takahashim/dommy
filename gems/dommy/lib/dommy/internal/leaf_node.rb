# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG puts `appendChild` / `insertBefore` / `replaceChild` /
    # `removeChild` on Node, so EVERY node has them — a leaf (CharacterData,
    # DocumentType) simply always rejects. Pre-insert and replace both check the
    # parent's type in step 1, before the reference child, so a leaf parent is a
    # HierarchyRequestError even when the reference is not a child of anything;
    # removeChild has nothing to remove and is a NotFoundError.
    #
    # Included by the leaf node classes, whose JS bridge dispatches to these so
    # the Ruby and JS surfaces cannot drift apart. Includers may override
    # `leaf_insertion_message`.
    module LeafNode
      def append_child(node)
        reject_leaf_insertion!(node)
      end

      def insert_before(node, _reference = nil)
        reject_leaf_insertion!(node)
      end

      def replace_child(node, _child = nil)
        reject_leaf_insertion!(node)
      end

      def remove_child(node)
        coerce_leaf_node_argument!(node)
        raise DOMException::NotFoundError, "the node to be removed is not a child of this node"
      end

      private

      def reject_leaf_insertion!(node)
        coerce_leaf_node_argument!(node)
        raise DOMException::HierarchyRequestError, leaf_insertion_message
      end

      # WebIDL coerces the Node argument first: a null / non-Node value is a
      # TypeError before any DOM step runs.
      def coerce_leaf_node_argument!(value)
        raise Bridge::TypeError, "Argument is not a Node." unless value.is_a?(Dommy::Node)
      end

      def leaf_insertion_message
        "this node type does not support children"
      end
    end
  end
end
