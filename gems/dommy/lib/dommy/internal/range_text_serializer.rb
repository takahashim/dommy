# frozen_string_literal: true

module Dommy
  module Internal
    # Collaborator that serializes a `Range` to its text content
    # (`Range#to_s`). Walks the range's common-ancestor subtree,
    # trimming the start/end text nodes by the boundary offsets and
    # concatenating contributions from every intersecting text node.
    #
    # Reads `Range` through its public surface (`start_container`,
    # `end_container`, `start_offset`, `end_offset`,
    # `common_ancestor_container`, `intersects_node`) — no peeking at
    # ivars, so `Range` is free to refactor its internals.
    class RangeTextSerializer
      def initialize(range)
        @range = range
      end

      def serialize
        return "" unless @range.common_ancestor_container

        sc, ec = @range.start_container, @range.end_container
        so, eo = @range.start_offset, @range.end_offset

        if sc.equal?(ec) && text_node?(sc)
          return sc.data.to_s[so, eo - so].to_s
        end

        pieces = []
        walk(@range.common_ancestor_container, pieces)
        pieces.join
      end

      private

      def walk(node, pieces)
        return unless node.respond_to?(:child_nodes)

        node.child_nodes.to_a.each do |child|
          if text_node?(child)
            contribution = text_contribution(child)
            pieces << contribution unless contribution.empty?
          elsif @range.intersects_node(child)
            walk(child, pieces)
          end
        end
      end

      def text_contribution(text_node)
        txt = text_node.data.to_s
        sc, ec = @range.start_container, @range.end_container
        so, eo = @range.start_offset, @range.end_offset

        if text_node.equal?(sc) && text_node.equal?(ec)
          txt[so, eo - so].to_s
        elsif text_node.equal?(sc)
          txt[so..].to_s
        elsif text_node.equal?(ec)
          txt[0, eo].to_s
        elsif @range.intersects_node(text_node)
          txt
        else
          ""
        end
      end

      def text_node?(node)
        node.respond_to?(:node_type) && node.node_type == 3
      end
    end
  end
end
