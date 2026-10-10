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
      def self.root_of(node) = node.root_node

      # More shadow trees nested in one another than any real page has.
      MAX_SHADOW_DEPTH = 100_000

      # Whether `node` (a backend node of `document`) is connected: its
      # shadow-including root is a document. From each tree's root to the
      # host of its shadow root, if it is one. Shadow trees do not nest in a
      # cycle; the cap only keeps a malformed chain from hanging.
      def self.connected?(node, document)
        current = node
        MAX_SHADOW_DEPTH.times do
          root = root_of(current)
          return true if root.is_a?(Backend.document_class)

          # Only a fragment can be a shadow root's.
          shadow_root = root.document_fragment? && document.__internal_shadow_root_for_fragment__(root)
          host = shadow_root && shadow_root.host
          return false unless host

          current = host.__dommy_backend_node__
        end
        false
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
