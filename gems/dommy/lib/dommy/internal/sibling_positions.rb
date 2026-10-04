# frozen_string_literal: true

module Dommy
  module Internal
    module SelectorMatcher
      # Where each element child of one parent stands, for `:nth-child` and
      # `:nth-of-type`: listed once, rather than once per sibling asked about,
      # which made matching a long list of siblings O(n²).
      #
      # Keyed by backend node. Built for the tree as it is when `version`
      # (the document's tree_version) was read; a holder that outlives a
      # mutation asks #current? before reusing one.
      class SiblingPositions
        attr_reader :version

        def initialize(parent_node, version)
          @children = parent_node.element_children.to_a
          @version = version
          @index = {}.compare_by_identity
          @children.each_with_index { |node, i| @index[node] = i }
        end

        def current?(version) = version == @version

        # The 1-based position of `node` among the children, from the end
        # when `reverse`.
        def of(node, reverse)
          position(@index[node], @children.size, reverse)
        end

        # The same among the children of `node`'s type (namespace and local
        # name, as the elements report them).
        def of_type(node, reverse)
          index = types[type_of(node)]
          position(index[node], index.size, reverse)
        end

        private

        def position(index, count, reverse)
          return nil unless index

          reverse ? count - index : index + 1
        end

        def types
          @types ||= @children.each_with_object({}) do |node, types|
            index = (types[type_of(node)] ||= {}.compare_by_identity)
            index[node] = index.size
          end
        end

        # The namespace and local name the element reports, read from its
        # node, as Element#namespace_uri and #local_name read them.
        def type_of(node) = [Backend.namespace_uri(node), node.local_name]
      end
    end
  end
end
