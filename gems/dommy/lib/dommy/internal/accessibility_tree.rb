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
        # Text is carried raw through construction so adjacent runs concatenate
        # with correct (block vs inline) spacing; collapse it to its final form
        # once, here.
        finalize_text(root)
        root
      end

      # Squish each text node's accumulated content and drop the empties,
      # depth-first. Coalescing already merged adjacent runs during build.
      def finalize_text(node)
        node.children = node.children.filter_map do |child|
          if child.text?
            text = squish(child.name)
            Node.new(role: :text, name: text) unless text.empty?
          else
            finalize_text(child)
            child
          end
        end
        node
      end

      # The accessible nodes an element contributes to its parent: 0 (excluded),
      # 1 (a real node), or many (its promoted children when it is
      # presentational / generic).
      def nodes_for(element)
        return [] if excluded?(element)
        return [] if lone_unscoped_th?(element)

        role = AriaRole.compute(element)
        children = build_children(element)

        # Presentational and generic/roleless containers drop out; their
        # children are promoted to the parent. A block-level box separates its
        # text from siblings, so its promoted run is padded with whitespace.
        if role == "none" || role == "" || role == "generic"
          return AccessibleName.block_level?(element) ? [text_node(" "), *children, text_node(" ")] : children
        end

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
        # When a node's sole content is text that just repeats its (author-
        # supplied) accessible name, that text is not exposed again
        # (aria-label="X">X is `banner "X"`, but a text sibling keeps it).
        node.children = [] if sole_name_text?(node)
        # A native range / number / color control shows its value as inline text.
        value = native_widget_value(element)
        node.children << text_node(value) if value
        [node]
      end

      def sole_name_text?(node)
        return false unless node.children.size == 1 && !node.name.to_s.empty?

        child = node.children.first
        child.text? && squish(child.name) == node.name
      end

      # Walk an element's child nodes in document order: significant text
      # becomes a :text node; elements recurse (and may promote).
      def build_children(element)
        out = []
        element.child_nodes.each do |child|
          if child.is_a?(Dommy::Element)
            out.concat(nodes_for(child))
          elsif child.is_a?(Dommy::TextNode)
            # Keep the text raw (whitespace and all); spacing is resolved when
            # adjacent runs are coalesced and finally squished.
            out << text_node(child.text_content.to_s)
          end
        end
        coalesce_text(out)
      end

      # Merge runs of adjacent text nodes into one by direct concatenation —
      # inline content glues ("Save" + "Save" -> "SaveSave"); the whitespace that
      # separates block-level content comes from the padding added when a
      # block box is promoted (see nodes_for).
      def coalesce_text(nodes)
        nodes.each_with_object([]) do |node, out|
          if node.text? && out.last&.text?
            out[-1] = text_node("#{out.last.name}#{node.name}")
          else
            out << node
          end
        end
      end

      def text_node(text) = Node.new(role: :text, name: text)

      # The displayed value of a native range / number / color input (the only
      # widgets whose value Chromium puts in the snapshot — ARIA aria-valuenow /
      # progress / meter show nothing). A range always shows a value (defaulting
      # to the midpoint of its min/max); color defaults to "#000000"; a number
      # shows one only when non-empty.
      def native_widget_value(element)
        return nil unless element.local_name.to_s.casecmp?("input")

        value = element.value.to_s
        case element.get_attribute("type").to_s.downcase
        when "range" then value.empty? ? range_default(element) : value
        when "color" then value.empty? ? "#000000" : value
        when "number" then value.empty? ? nil : value
        end
      end

      def range_default(element)
        min = numeric(element.get_attribute("min"), 0.0)
        max = numeric(element.get_attribute("max"), 100.0)
        format_number(min + ((max - min) / 2.0))
      end

      def numeric(value, fallback)
        Float(value)
      rescue ArgumentError, TypeError
        fallback
      end

      def format_number(number)
        number == number.to_i ? number.to_i.to_s : number.to_s
      end

      # An element (and its whole subtree) is excluded from the tree when
      # `aria-hidden="true"` or when it is not visually rendered. `visible?`
      # deliberately ignores aria-hidden, so it is checked here.
      def excluded?(element)
        return true if element.get_attribute("aria-hidden").to_s.casecmp?("true")

        !DomMatching.visible?(element)
      end

      # A lone, unscoped <th> that is the only cell of the only row of its table
      # is not emitted as a header cell — Chromium folds it into the row's
      # accessible name. An explicit `scope`, a sibling cell, or a second row all
      # make it a real header.
      def lone_unscoped_th?(element)
        return false unless element.local_name.to_s.casecmp?("th")
        return false unless element.get_attribute("scope").to_s.empty?

        table = element.respond_to?(:closest) ? element.closest("table") : nil
        return false unless table

        rows = table.query_selector_all("tr").to_a
        return false unless rows.size == 1

        rows.first.query_selector_all("td, th").to_a.size == 1
      end

      def squish(text) = text.to_s.gsub(/\s+/, " ").strip
    end
  end
end
