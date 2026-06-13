# frozen_string_literal: true

module Dommy
  module Internal
    # Splits raw stylesheet text into individual rule slices and pulls a
    # single rule apart into its prelude (selector / at-rule condition) and
    # body — enough to back the CSSOM CSSRule accessors (selectorText, style,
    # nested cssRules) without re-tokenizing the whole grammar. Each slice is
    # kept verbatim so CSSRule#cssText round-trips the source until mutated.
    #
    # This is deliberately a lightweight scanner (it tracks brace depth,
    # string literals and `/* */` comments); the cascade's correctness still
    # comes from lexbor. It exists only to give JS-visible CSSOM introspection.
    module CSSRuleText
      module_function

      # Top-level rule slices in source order, each stripped of surrounding
      # whitespace. Block rules (`sel { ... }`, `@media ... { ... }`) span to
      # their matching `}`; statement at-rules (`@import ...;`) span to `;`.
      def split_rules(text)
        text = text.to_s
        rules = []
        start = nil
        depth = 0
        string = nil
        i = 0
        len = text.length

        while i < len
          ch = text[i]

          if string
            if ch == "\\"
              i += 2
              next
            end
            string = nil if ch == string
            i += 1
            next
          end

          if ch == "/" && text[i + 1] == "*"
            close = text.index("*/", i + 2)
            i = (close || len - 2) + 2
            next
          end

          case ch
          when '"', "'"
            start ||= i
            string = ch
          when "{"
            start ||= i
            depth += 1
          when "}"
            depth -= 1 if depth.positive?
            if depth.zero? && start
              rules << text[start..i]
              start = nil
            end
          when ";"
            if depth.zero? && start
              rules << text[start..i]
              start = nil
            end
          else
            start ||= i unless ch.match?(/\s/)
          end

          i += 1
        end

        rules << text[start..] if start
        rules.map(&:strip).reject(&:empty?)
      end

      # [prelude, body] for one rule slice. `body` is the text between the
      # outermost braces, or nil for a braceless statement at-rule. `prelude`
      # is the selector list (style rule) or the at-rule keyword + condition.
      def split_rule(text)
        text = text.to_s
        brace = top_level_brace(text)
        return [text.sub(/;\s*\z/, "").strip, nil] unless brace

        prelude = text[0...brace].strip
        close = matching_brace(text, brace)
        body = text[(brace + 1)...(close || text.length)].to_s
        [prelude, body]
      end

      # The at-rule keyword (lowercased, without `@`) of a prelude, or nil for
      # a plain style rule.
      def at_keyword(prelude)
        match = prelude.to_s.match(/\A@(-?[a-z][a-z-]*)/i)
        match && match[1].downcase
      end

      # Index of the first `{` at brace depth 0, skipping strings and comments.
      def top_level_brace(text)
        scan_braces(text, 0) { |ch, i| return i if ch == "{" }
        nil
      end

      # Index of the `}` matching the `{` at `open`, skipping nested braces,
      # strings and comments. nil when unterminated.
      def matching_brace(text, open)
        depth = 0
        scan_braces(text, open) do |ch, i|
          depth += 1 if ch == "{"
          if ch == "}"
            depth -= 1
            return i if depth.zero?
          end
        end
        nil
      end

      # Walk `text` from `from`, yielding [char, index] for each `{`/`}` that
      # lies outside string literals and `/* */` comments.
      def scan_braces(text, from)
        string = nil
        i = from
        len = text.length
        while i < len
          ch = text[i]
          if string
            if ch == "\\"
              i += 2
              next
            end
            string = nil if ch == string
          elsif ch == "/" && text[i + 1] == "*"
            i = (text.index("*/", i + 2) || len - 2) + 2
            next
          elsif ch == '"' || ch == "'"
            string = ch
          elsif ch == "{" || ch == "}"
            yield ch, i
          end
          i += 1
        end
      end
    end
  end
end
