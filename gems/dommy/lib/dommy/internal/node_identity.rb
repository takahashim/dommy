# frozen_string_literal: true

module Dommy
  module Internal
    # Whether two DOM references stand for the same node.
    #
    # Comparing the backend nodes with `==` is not it: a backend may mint a
    # fresh wrapper per traversal, and one that frees nodes may hand the same
    # pointer to a later node. Backend.identity_key is what each backend says
    # its stable key is (see NodeWrapperCache#identity_key), so that is what
    # this asks — in one place, because three callers used to answer it three
    # ways.
    module NodeIdentity
      module_function

      # `first` and `second` may be wrappers or backend nodes, in any mix.
      def same_node?(first, second)
        return false unless first && second

        left = key_for(first)
        right = key_for(second)
        !left.nil? && left == right
      end

      def key_for(node)
        backend = node.respond_to?(:__dommy_backend_node__) ? node.__dommy_backend_node__ : node
        backend && Backend.identity_key(backend)
      end
    end
  end
end
