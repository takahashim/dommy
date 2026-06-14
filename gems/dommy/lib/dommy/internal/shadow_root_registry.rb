# frozen_string_literal: true

require_relative "node_traversal"

module Dommy
  module Internal
    # Manages ShadowRoot identity and shadow boundary traversal.
    # Maps Nokogiri DocumentFragment (shadow tree backing) to ShadowRoot wrapper.
    class ShadowRootRegistry
      def initialize
        @shadow_roots = {}
      end

      # Register a shadow root by its backing fragment node
      def register(fragment_node, shadow_root)
        @shadow_roots[Backend.identity_key(fragment_node)] = shadow_root
      end

      # Find the ShadowRoot for a given fragment (if any)
      def find_for_fragment(fragment_node)
        return nil unless fragment_node
        @shadow_roots[Backend.identity_key(fragment_node)]
      end

      # Every registered ShadowRoot (used by the cascade to collect shadow-tree
      # stylesheets). Insertion order; includes roots whose host may have since
      # been detached (harmless — their rules only match their own subtree).
      def all
        @shadow_roots.values
      end

      # Find the enclosing ShadowRoot for a given node.
      # Walks up the ancestor chain looking for a shadow root.
      # Uses NodeTraversal to avoid duplication of tree walking logic.
      def find_enclosing(nokogiri_node)
        NodeTraversal.find_ancestor(nokogiri_node) do |ancestor|
          find_for_fragment(ancestor)
        end
      end
    end
  end
end
