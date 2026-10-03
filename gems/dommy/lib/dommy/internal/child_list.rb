# frozen_string_literal: true

module Dommy
  module Internal
    # The fast path of a node's live child lists (`childNodes`, `children`):
    # how many there are and which is the nth, asked of the backend, so only
    # the one asked for is wrapped. Without it each `length` or `[i]` wrapped
    # every child, and a loop over a list's indices — idiomorph's,
    # morphdom's — was O(n²).
    #
    # The backend lists every child to answer either, so a list also keeps
    # its length and the last child it was asked for until the tree changes
    # (the document's tree_version moves): the next index, or the one
    # before, is a sibling step from there. A loop over every index is then
    # O(n).
    #
    # `node` and `document` answer the owner's backend node and document
    # when the list is asked rather than when it is made, so an adopted
    # node's lists follow it.
    class ChildList
      def self.nodes(node, document) = new(node, document, elements: false).callables

      def self.elements(node, document) = new(node, document, elements: true).callables

      def initialize(node, document, elements:)
        @node = node
        @document = document
        @elements = elements
      end

      def callables = {count: method(:count), at: method(:at)}

      def count
        sync
        @count ||= children.size
      end

      def at(index)
        sync
        child = near(index) || children[index]
        return nil unless child

        @index = index
        @child = child
        @document.call.wrap_node(child)
      end

      private

      # Forget what was kept once the tree has changed, or the owner's
      # backend node has (an adopted node's is a copy).
      def sync
        owner = @node.call
        version = owner.document.tree_version
        return if owner.equal?(@owner) && version == @version

        @owner = owner
        @version = version
        @count = @index = @child = nil
      end

      def children = @elements ? @owner.element_children : @owner.children

      def near(index)
        return nil unless @index

        case index - @index
        when 0 then @child
        when 1 then @elements ? @child.next_element : @child.next_sibling
        when -1 then @elements ? @child.previous_element : @child.previous_sibling
        end
      end
    end
  end
end
