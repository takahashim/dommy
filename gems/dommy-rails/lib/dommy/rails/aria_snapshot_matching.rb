# frozen_string_literal: true

module Dommy
  module Rails
    # Compares a Playwright-compatible ARIA snapshot against an expected
    # template using Playwright's `toMatchAriaSnapshot` semantics: a SUBSET
    # match. Every node listed in `expected` must appear in `actual`, in order,
    # at the same nesting — but `actual` may contain extra nodes. A node matches
    # when role + (optional) name + (subset of) flags agree. An expected name
    # written as `/pattern/` is matched as a regular expression; an omitted name
    # is a wildcard.
    module AriaSnapshotMatching
      Node = Struct.new(:role, :name, :name_regex, :flags, :children, keyword_init: true)

      module_function

      def matches?(actual_text, expected_text)
        children_match?(parse(expected_text).children, parse(actual_text).children)
      end

      # --- comparison ---

      def node_match?(expected, actual)
        return false unless expected.role == actual.role
        return false unless name_match?(expected, actual)
        return false unless (expected.flags - actual.flags).empty?

        children_match?(expected.children, actual.children)
      end

      def name_match?(expected, actual)
        return actual.name.to_s.match?(expected.name_regex) if expected.name_regex
        return true if expected.name.nil?

        expected.name == actual.name
      end

      # Greedy ordered-subsequence match: each expected child must match a later
      # actual child, allowing extra actual children in between.
      def children_match?(expected_children, actual_children)
        cursor = 0
        expected_children.each do |expected|
          cursor += 1 until cursor >= actual_children.size || node_match?(expected, actual_children[cursor])
          return false if cursor >= actual_children.size

          cursor += 1
        end
        true
      end

      # --- parsing (indentation outline -> Node tree) ---

      def parse(text)
        root = Node.new(role: nil, flags: [], children: [])
        stack = [[-1, root]]
        text.to_s.each_line do |line|
          stripped = line.strip
          next if stripped.empty? || !stripped.start_with?("- ")

          indent = line[/\A */].length
          node = parse_line(stripped[2..])
          stack.pop while stack.size > 1 && stack.last[0] >= indent
          stack.last[1].children << node
          stack.push([indent, node])
        end
        root
      end

      def parse_line(body)
        body = body.sub(/:\s*\z/, "")
        return Node.new(role: "text", name: unquote(body.sub(/\Atext:\s*/, "")), flags: [], children: []) \
          if body.start_with?("text:")

        role, rest = body.split(/\s+/, 2)
        name, name_regex, rest = scan_name(rest)
        flags = rest.to_s.scan(/\[([^\]]*)\]/).flatten
        Node.new(role: role, name: name, name_regex: name_regex, flags: flags, children: [])
      end

      def scan_name(rest)
        return [nil, nil, rest] if rest.nil?

        if rest.start_with?('"') && (md = rest.match(/\A"((?:\\.|[^"\\])*)"/))
          [unescape(md[1]), nil, rest[md.end(0)..].to_s.strip]
        elsif rest.start_with?("/") && (md = rest.match(%r{\A/((?:\\.|[^/\\])*)/}))
          [nil, Regexp.new(md[1]), rest[md.end(0)..].to_s.strip]
        else
          [nil, nil, rest]
        end
      end

      def unquote(text)
        md = text.to_s.strip.match(/\A"((?:\\.|[^"\\])*)"\z/)
        md ? unescape(md[1]) : text.to_s.strip
      end

      def unescape(text) = text.gsub(/\\(.)/, '\1')
    end
  end
end
