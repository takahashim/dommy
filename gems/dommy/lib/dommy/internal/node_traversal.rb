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
        current = node.respond_to?(:parent) ? node.parent : nil
        while current && !current.is_a?(Backend.document_class)
          yield current
          current = current.respond_to?(:parent) ? current.parent : nil
        end
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
        root.children.each { |child| nodes.concat(subtree_nodes(child)) } if root.respond_to?(:children)
        nodes
      end

      # Find the first ancestor matching a predicate.
      # Returns the result of the block, not the node itself.
      def self.find_ancestor(node)
        each_ancestor(node) { |n|
          result = yield(n)
          return result if result
        }
        nil
      end
    end
  end
end
