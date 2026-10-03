# frozen_string_literal: true

module Dommy
  module Internal
    # The fast path of a node's live child lists (`childNodes`, `children`):
    # how many there are and which is the nth, asked of the backend, which
    # lists children natively, so only the one asked for is wrapped. Without
    # it each `length` or `[i]` wrapped every child, and a loop over a
    # list's indices — idiomorph's, morphdom's — was O(n²).
    #
    # `node` and `document` answer the owner's backend node and document
    # when the list is asked rather than when it is made, so an adopted
    # node's lists follow it.
    module ChildList
      module_function

      def nodes(node, document)
        {
          count: -> { node.call.children.size },
          at: ->(i) { wrap(document, node.call.children[i]) },
        }
      end

      def elements(node, document)
        {
          count: -> { node.call.element_children.size },
          at: ->(i) { wrap(document, node.call.element_children[i]) },
        }
      end

      def wrap(document, backend_node) = backend_node && document.call.wrap_node(backend_node)
      private_class_method :wrap
    end
  end
end
