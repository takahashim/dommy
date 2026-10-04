# frozen_string_literal: true

module Dommy
  module Internal
    # Node tree traversal utilities.
    # Centralizes ancestor walking logic to hide Nokogiri implementation details.
    # Prevents duplication of tree traversal code across Observer, EventTarget, etc.
    module NodeTraversal
      # Walk from a node up to document, yielding each ancestor.
      # Stops at Nokogiri::XML::Document (the root).
      def self.each_ancestor(node)
        current = node&.parent
        while current && !current.is_a?(Backend.document_class)
          yield current
          current = current.parent
        end
      end

      # The root of the tree a backend node is in: its topmost inclusive
      # ancestor, the backend document when it is attached.
      def self.root_of(node)
        while (parent = node.parent)
          node = parent
        end
        node
      end

      # Check if ancestor is an ancestor of node.
      def self.ancestor_of?(ancestor, node)
        each_ancestor(node) { |n| return true if n == ancestor }
        false
      end

      # The backend nodes of `root`'s subtree, `root` first, in document order.
      # Two such lists taken from an original and its copy line up index by
      # index, which is how the adopt and the cloning steps pair a node with the
      # copy that stands in for it.
      def self.subtree_nodes(root)
        nodes = [root]
        root.children.each { |child| nodes.concat(subtree_nodes(child)) }
        nodes
      end
    end
  end
end
