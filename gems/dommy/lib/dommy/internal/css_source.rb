# frozen_string_literal: true

module Dommy
  module Internal
    # Reading CSS source text by hand without mistaking the inside of a token
    # for structure.
    #
    # css-syntax-3 reads tokens, and four of them carry characters that look
    # like structure but are not: an escape (`\;`, `\,`, `\)` belong to an
    # ident, §4.3.8), a string (its `;`, `:` and `,` are its value, §4.3.5),
    # an unquoted url (`url(a/*b.png)` and `url(it's.png)` hold no comment and
    # no string, §4.3.6), and a comment (no token at all, §4.3.2). Anything
    # that splits, balances or searches CSS source by characters has to step
    # over those whole — which is what this module is for, so the selector
    # parser, the declaration-block parser and var() substitution all answer
    # it the same way.
    module CssSource
      OPENING_BRACKETS = "([{"
      CLOSING_BRACKETS = ")]}"
      # css-syntax-3's whitespace (§4.2).
      WHITESPACE = " \t\n\r\f"
      # css-syntax-3 §4.2 "non-ASCII ident code point". Not everything from
      # U+0080 up: the spec narrowed it to this list, aligned with HTML's valid
      # custom element name. U+2603 SNOWMAN falls between two of the ranges, so
      # it cannot be written into a selector at all except escaped (`.\2603 `).
      NON_ASCII_IDENT_RANGES = [
        0xB7..0xB7, 0xC0..0xD6, 0xD8..0xF6, 0xF8..0x37D, 0x37F..0x1FFF,
        0x200C..0x200D, 0x203F..0x2040, 0x2070..0x218F, 0x2C00..0x2FEF,
        0x3001..0xD7FF, 0xF900..0xFDCF, 0xFDF0..0xFFFD,
      ].freeze

      module_function

      # §4.3.8: a backslash at `j` starts a valid escape unless a newline
      # follows it. Every other pair counts, the end of the input included.
      def valid_escape_at?(source, j)
        source[j] == "\\" && source[j + 1] != "\n"
      end

      # §4.2 ident-start code point: a letter, an underscore, or a non-ASCII
      # ident code point. nil (past the end) is none.
      def ident_start_code_point?(c)
        return false if c.nil?

        c.match?(/[A-Za-z_]/) || non_ascii_ident_code_point?(c)
      end

      # §4.2 ident code point: an ident-start one, a digit, or U+002D.
      def name_code_point?(c)
        return false if c.nil?

        c.match?(/[A-Za-z0-9_\-]/) || non_ascii_ident_code_point?(c)
      end

      def non_ascii_ident_code_point?(c)
        codepoint = c.ord
        return false if codepoint < 0x80
        return true if codepoint >= 0x10000

        NON_ASCII_IDENT_RANGES.any? { |range| range.cover?(codepoint) }
      end

      # Index just past the escape, string, unquoted url or comment starting
      # at `j`, or nil if none starts there. A string ends at its closing
      # quote, or before a newline or the end of the input; a url at its `)`
      # or the end of the input; a comment at its `*/` or the end of the input.
      def atom_end(source, j)
        c = source[j]
        if (c == "u" || c == "U") && (k = url_contents_start(source, j))
          url_end(source, k)
        elsif c == "\\"
          return nil unless valid_escape_at?(source, j)

          [j + 2, source.length].min
        elsif c == '"' || c == "'"
          k = j + 1
          while k < source.length
            d = source[k]
            return k + 1 if d == c
            return k if d == "\n"

            k += d == "\\" ? 2 : 1
          end
          source.length
        elsif c == "/" && source[j + 1] == "*"
          close = source.index("*/", j + 2)
          close ? close + 2 : source.length
        end
      end

      # Where an unquoted url token's contents start, if the ident `url`
      # (ASCII case-insensitive, not the tail of a longer name) followed by
      # `(` starts at `j` — after the whitespace the url skips. A quote there
      # makes it a `url(` function holding a string instead (§4.3.4).
      def url_contents_start(source, j)
        return nil unless source[j, 4].casecmp?("url(")
        return nil if j.positive? && name_code_point?(source[j - 1])

        k = j + 4
        k += 1 while k < source.length && WHITESPACE.include?(source[k])
        q = source[k]
        q == '"' || q == "'" ? nil : k
      end

      # Index just past the `)` closing an unquoted url whose contents start
      # at `k`, or the end of the input. An escape is stepped over; whatever
      # else would make the url bad (§4.3.6's consume the remnants of a bad
      # url) still ends at the same `)`.
      def url_end(source, k)
        while k < source.length
          d = source[k]
          return k + 1 if d == ")"

          k += valid_escape_at?(source, k) ? 2 : 1
        end
        source.length
      end

      # The index of the first `char` at or after `from` that is outside every
      # escape, string, comment and bracket, or nil.
      def index_top_level(source, char, from = 0)
        depth = 0
        i = from
        while i < source.length
          if (j = atom_end(source, i))
            i = j
            next
          end

          c = source[i]
          return i if c == char && depth.zero?

          if OPENING_BRACKETS.include?(c)
            depth += 1
          elsif CLOSING_BRACKETS.include?(c)
            depth -= 1 if depth.positive?
          end
          i += 1
        end
        nil
      end

      # The next call of the function `name` at or after `from`, outside every
      # escape, string, url and comment: `[start, close]`, where `start` is
      # where its name begins (matched ASCII case-insensitively, and not the
      # tail of a longer name) and `close` is its `)`, or nil when it is never
      # closed. nil when there is no such call.
      def next_function(source, name, from = 0)
        head = "#{name}("
        i = from
        while i < source.length
          if (j = atom_end(source, i))
            i = j
            next
          end
          if source[i, head.length].casecmp?(head) && (i.zero? || !name_code_point?(source[i - 1]))
            return [i, matching_bracket(source, i + name.length)]
          end

          i += 1
        end
        nil
      end

      # `source` split at every top-level `char` (see #index_top_level).
      def split_top_level(source, char)
        parts = []
        start = 0
        while (i = index_top_level(source, char, start))
          parts << source[start...i]
          start = i + 1
        end
        parts << source[start..].to_s
      end

      # The index of the bracket closing the one at `open`, or nil when it is
      # never closed. Every kind of bracket opens a level, and escapes, strings
      # and comments are stepped over.
      def matching_bracket(source, open)
        depth = 0
        i = open
        while i < source.length
          if i > open && (j = atom_end(source, i))
            i = j
            next
          end

          c = source[i]
          if OPENING_BRACKETS.include?(c)
            depth += 1
          elsif CLOSING_BRACKETS.include?(c)
            depth -= 1
            return i if depth.zero?
          end
          i += 1
        end
        nil
      end

      # `source` with its comments removed. A comment is no token, but it does
      # separate the tokens on either side (`1px/**/solid` is two), so one
      # between two non-whitespace characters leaves a space behind. One with
      # whitespace on both sides leaves that whitespace once: the whitespace
      # after it joins the run before it (`1px /* c */ + 2px` is `1px + 2px`).
      def strip_comments(source)
        return source unless source.include?("/*")

        out = +""
        i = 0
        while i < source.length
          j = atom_end(source, i)
          if j && source[i] == "/"
            before = out[-1]
            after = source[j]
            before_space = before.nil? || WHITESPACE.include?(before)
            after_space = after.nil? || WHITESPACE.include?(after)
            if before_space && !before.nil?
              j += 1 while j < source.length && WHITESPACE.include?(source[j])
            elsif !before_space && !after_space
              out << " "
            end
            i = j
          elsif j
            out << source[i...j]
            i = j
          else
            out << source[i]
            i += 1
          end
        end
        out
      end

      private_class_method :non_ascii_ident_code_point?, :url_contents_start, :url_end
    end
  end
end
