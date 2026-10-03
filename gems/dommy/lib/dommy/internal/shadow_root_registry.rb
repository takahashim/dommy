# frozen_string_literal: true

require_relative "node_traversal"

module Dommy
  module Internal
    # Manages ShadowRoot identity and shadow boundary traversal.
    # Maps Nokogiri DocumentFragment (shadow tree backing) to ShadowRoot wrapper.
    class ShadowRootRegistry
      def initialize
        @shadow_roots = {}
        @by_host = {}
      end

      # Register a shadow root by its backing fragment node, and by its host's
      # node: the host's wrapper can be replaced (a custom element upgrade
      # re-wraps it) while the shadow root stays attached.
      def register(fragment_node, shadow_root)
        @shadow_roots[Backend.identity_key(fragment_node)] = shadow_root
        @by_host[Backend.identity_key(shadow_root.host.__dommy_backend_node__)] = shadow_root
      end

      # The ShadowRoot attached to the element backed by `host_node`, if any.
      def find_for_host(host_node)
        return nil unless host_node

        @by_host[Backend.identity_key(host_node)]
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

      # The ShadowRoot whose tree the node is in, its own fragment aside. A
      # shadow root's fragment is the root of its tree, so it can only be the
      # node's root.
      def find_enclosing(nokogiri_node)
        return nil unless nokogiri_node.respond_to?(:parent)

        root = NodeTraversal.root_of(nokogiri_node)
        find_for_fragment(root) unless root.equal?(nokogiri_node)
      end
    end
  end
end
