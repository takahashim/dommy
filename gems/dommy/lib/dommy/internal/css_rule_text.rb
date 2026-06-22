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
      #
      # Scans over the BINARY bytes, not the UTF-8 characters: every byte we
      # branch on ({ } " ' / * ; \\ and ASCII whitespace) is 7-bit, and a UTF-8
      # multibyte sequence is wholly bytes >= 0x80 — none of which collide with
      # those, so the structure is read identically while `bytes[i]` stays O(1)
      # (UTF-8 `String#[i]` is O(i), making the whole scan O(n^2) — the dominant
      # cost on a large stylesheet). Slice boundaries always land on a 7-bit byte
      # (a delimiter) or a UTF-8 lead byte (the first non-space of a prelude), so
      # each byteslice is a whole-character substring; re-tag it UTF-8 on the way
      # out so the verbatim rule text round-trips unchanged.
      def split_rules(text)
        bytes = text.to_s.b
        rules = []
        start = nil
        depth = 0
        string = nil
        i = 0
        len = bytes.length

        while i < len
          ch = bytes[i]

          if string
            if ch == "\\"
              i += 2
              next
            end
            string = nil if ch == string
            i += 1
            next
          end

          if ch == "/" && bytes[i + 1] == "*"
            close = bytes.index("*/", i + 2)
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
              rules << bytes[start..i]
              start = nil
            end
          when ";"
            if depth.zero? && start
              rules << bytes[start..i]
              start = nil
            end
          else
            start ||= i unless ch.match?(/\s/)
          end

          i += 1
        end

        rules << bytes[start..] if start
        rules.map { |slice| slice.force_encoding(Encoding::UTF_8).strip }.reject(&:empty?)
      end

      # [prelude, body] for one rule slice. `body` is the text between the
      # outermost braces, or nil for a braceless statement at-rule. `prelude`
      # is the selector list (style rule) or the at-rule keyword + condition.
      #
      # Walks the BINARY bytes for the same reason as #split_rules: the brace
      # scan is O(1) per byte instead of O(i) per UTF-8 character. Brace indices
      # land on the 7-bit `{`/`}`, so every byteslice is a whole-character
      # substring; re-tag the pieces UTF-8.
      def split_rule(text)
        bytes = text.to_s.b
        brace = top_level_brace(bytes)
        return [bytes.force_encoding(Encoding::UTF_8).sub(/;\s*\z/, "").strip, nil] unless brace

        prelude = bytes[0...brace].force_encoding(Encoding::UTF_8).strip
        close = matching_brace(bytes, brace)
        body = bytes[(brace + 1)...(close || bytes.length)].to_s.force_encoding(Encoding::UTF_8)
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
