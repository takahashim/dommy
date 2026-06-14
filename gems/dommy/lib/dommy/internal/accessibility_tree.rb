# frozen_string_literal: true

module Dommy
  module Internal
    # Builds the *accessibility tree* of a DOM scope: the tree of accessible
    # objects an assistive technology would see, computed from role, name,
    # description, and ARIA state, with the DOM-to-a11y inclusion rules applied
    # (hidden subtrees removed, presentational and generic nodes flattened,
    # name-from-content text folded into the name). It is the structure an ARIA
    # snapshot serializes and a getByRole query would walk.
    #
    # Fidelity follows Playwright's aria snapshot rather than the letter of the
    # ARIA spec where they differ (generic containers collapse even when named;
    # name-from-content roles drop descendant *text* but keep descendant *roled*
    # nodes). aria-owns reparenting is out of scope for now.
    module AccessibilityTree
      # One accessible object. A `:text` node carries its string in `name` and
      # has no children — it is significant text not folded into an ancestor.
      class Node
        attr_reader :role, :name, :description, :states, :element
        attr_accessor :children

        def initialize(role:, name: "", description: "", states: {}, element: nil)
          @role = role
          @name = name
          @description = description
          @states = states
          @element = element
          @children = []
        end

        def text? = role == :text
        # The heading level (or any leveled role) lives in `states`.
        def level = states[:level]

        def to_h
          hash = {role: role}
          hash[:name] = name unless name.to_s.empty?
          hash[:description] = description unless description.to_s.empty?
          hash[:states] = states unless states.empty?
          hash[:children] = children.map(&:to_h) unless children.empty?
          hash
        end
      end

      module_function

      # Build the tree for `scope` (a Document — started at its <body> — or an
      # Element). Returns a synthetic `:root` Node whose children are the
      # accessible nodes the scope contributes (so a Document has no document
      # line, matching Playwright).
      def build(scope)
        start = scope.respond_to?(:body) ? scope.body : scope
        root = Node.new(role: :root, element: scope)
        root.children = start ? nodes_for(start) : []
        root
      end

      # The accessible nodes an element contributes to its parent: 0 (excluded),
      # 1 (a real node), or many (its promoted children when it is
      # presentational / generic).
      def nodes_for(element)
        return [] if excluded?(element)

        role = AriaRole.compute(element)
        children = build_children(element)

        # Presentational and generic/roleless containers drop out; their
        # children are promoted to the parent.
        return children if role == "none" || role == "" || role == "generic"

        node = Node.new(
          role: role,
          name: AccessibleName.compute(element),
          description: AccessibleDescription.compute(element),
          states: AriaState.compute(element, role),
          element: element
        )
        # Name-from-content roles fold their descendant text into the name, so
        # those text nodes are not emitted again; descendant roled nodes stay.
        node.children = AccessibleName::NAME_FROM_CONTENT.include?(role) ? children.reject(&:text?) : children
        [node]
      end

      # Walk an element's child nodes in document order: significant text
      # becomes a :text node; elements recurse (and may promote).
      def build_children(element)
        out = []
        element.child_nodes.each do |child|
          if child.is_a?(Dommy::Element)
            out.concat(nodes_for(child))
          elsif child.is_a?(Dommy::TextNode)
            text = squish(child.text_content.to_s)
            out << Node.new(role: :text, name: text) unless text.empty?
          end
        end
        coalesce_text(out)
      end

      # Merge runs of adjacent text nodes into one (joined by a space), matching
      # how the snapshot presents contiguous text. Promotion of a collapsed
      # element's text children can place two text nodes side by side, so this
      # runs after the children are assembled.
      def coalesce_text(nodes)
        nodes.each_with_object([]) do |node, out|
          if node.text? && out.last&.text?
            out[-1] = Node.new(role: :text, name: "#{out.last.name} #{node.name}")
          else
            out << node
          end
        end
      end

      # An element (and its whole subtree) is excluded from the tree when
      # `aria-hidden="true"` or when it is not visually rendered. `visible?`
      # deliberately ignores aria-hidden, so it is checked here.
      def excluded?(element)
        return true if element.get_attribute("aria-hidden").to_s.casecmp?("true")

        !DomMatching.visible?(element)
      end

      def squish(text) = text.to_s.gsub(/\s+/, " ").strip
    end
  end
end
