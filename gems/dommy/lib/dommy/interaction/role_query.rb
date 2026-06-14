# frozen_string_literal: true

module Dommy
  module Interaction
    # Finds elements by their computed ARIA role (the accessibility-tree
    # counterpart of Testing Library's getByRole). It walks the accessibility
    # tree built for a scope, so the inclusion rules already applied there —
    # aria-hidden and invisible subtrees excluded, presentational/generic nodes
    # flattened — come for free. A node matches by role, optional accessible
    # name (substring by default; `exact: true` or a Regexp for precision), and
    # optional level.
    #
    # The single query path is shared by Driver#find_by_role / #all_by_role /
    # #has_role?, the have_role matcher, and assert_dom_has_role.
    module RoleQuery
      module_function

      # The elements under `scope` whose accessible node matches, in document
      # order. `scope` may be an Element/Document (queried directly), a Session
      # (its current document), or anything AccessibilityTree.build accepts.
      def match(scope, role:, name: nil, level: nil, exact: false)
        nodes = []
        collect(tree_for(scope), nodes)
        nodes.select { |node| node_matches?(node, role, name, level, exact) }.map(&:element)
      end

      # Human-readable "role" / "role \"name\"" descriptors of every accessible
      # node in scope — the candidates a failed find_by_role lists.
      def available(scope)
        nodes = []
        collect(tree_for(scope), nodes)
        nodes.map { |node| node.name.to_s.empty? ? node.role.to_s : "#{node.role} #{node.name.inspect}" }.uniq
      end

      def tree_for(scope)
        return scope.accessibility_tree if scope.respond_to?(:accessibility_tree)
        return scope.document.accessibility_tree if scope.respond_to?(:document) && scope.document

        Internal::AccessibilityTree.build(scope)
      end

      # Depth-first collect of nodes backed by a real element (skips :text and
      # the synthetic :root).
      def collect(node, out)
        node.children.each do |child|
          out << child if child.element
          collect(child, out)
        end
      end

      def node_matches?(node, role, name, level, exact)
        node.role.to_s == role.to_s &&
          (name.nil? || Internal::DomMatching.text_matches?(node.name, name, exact: exact)) &&
          (level.nil? || node.level == level)
      end
    end
  end
end
