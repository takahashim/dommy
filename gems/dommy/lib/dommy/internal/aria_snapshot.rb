# frozen_string_literal: true

module Dommy
  module Internal
    # Serializes an AccessibilityTree into a Playwright-compatible ARIA snapshot
    # (a YAML-ish indented outline). Each accessible node is a line
    #
    #   - <role> "<name>" [flag] [level=N]:
    #
    # with a trailing ":" only when it has children, 2-space indentation per
    # depth, and significant text as `- text: "…"`. The synthetic root is not
    # printed (a document has no top line), matching Playwright.
    module AriaSnapshot
      # The serialized flags, in fixed render order. A boolean flag renders only
      # when true or "mixed"; `level` renders as `[level=N]`.
      FLAG_ORDER = %i[checked disabled expanded level pressed readonly required selected].freeze

      module_function

      def serialize(root)
        lines = []
        root.children.each { |child| emit(child, 0, lines) }
        return "" if lines.empty?

        "#{lines.join("\n")}\n"
      end

      def emit(node, depth, lines)
        indent = "  " * depth
        if node.text?
          lines << "#{indent}- text: #{quote(node.name)}"
          return
        end

        header = "#{indent}- #{node.role}"
        header += " #{quote(node.name)}" unless node.name.to_s.empty?
        flags(node.states).each { |flag| header += " #{flag}" }
        header += ":" unless node.children.empty?
        lines << header

        node.children.each { |child| emit(child, depth + 1, lines) }
      end

      # The bracketed flag tokens for a node's states, in FLAG_ORDER. Booleans
      # render only when true/"mixed"; a "mixed" value renders `[flag=mixed]`.
      def flags(states)
        FLAG_ORDER.filter_map do |key|
          value = states[key]
          if key == :level
            "[level=#{value}]" if value
          elsif value == "mixed"
            "[#{key}=mixed]"
          elsif value == true
            "[#{key}]"
          end
        end
      end

      def quote(text) = "\"#{text.to_s.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
    end
  end
end
