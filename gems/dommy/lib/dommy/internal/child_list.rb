# frozen_string_literal: true

module Dommy
  module Internal
    # The fast path of a node's live child lists (`childNodes`, `children`):
    # how many there are and which is the nth, asked of the backend, so only
    # the one asked for is wrapped. Makiri counts and indexes a child list
    # without building it, and steps from the child it last handed out, so a
    # loop over a list's indices — idiomorph's, morphdom's — is O(n).
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
        owner = @node.call
        @elements ? owner.element_child_count : owner.child_count
      end

      def at(index)
        owner = @node.call
        child = @elements ? owner.element_child_at(index) : owner.child_at(index)
        child && @document.call.wrap_node(child)
      end
    end
  end
end
