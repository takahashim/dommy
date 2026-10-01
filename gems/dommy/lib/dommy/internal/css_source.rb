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
      # css-syntax-3's whitespace (§4.2) and name code points (§4.2), the
      # latter as a single character class.
      WHITESPACE = " \t\n\r\f"
      NAME_CODE_POINT = /[A-Za-z0-9_\-\u0080-\u{10FFFF}]/

      module_function

      # Index just past the escape, string, unquoted url or comment starting
      # at `j`, or nil if none starts there. A string ends at its closing
      # quote, or before a newline or the end of the input; a url at its `)`
      # or the end of the input; a comment at its `*/` or the end of the input.
      def atom_end(source, j)
        c = source[j]
        if (c == "u" || c == "U") && (k = url_contents_start(source, j))
          url_end(source, k)
        elsif c == "\\"
          return nil if source[j + 1] == "\n" # not a valid escape

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
        return nil if j.positive? && source[j - 1].match?(NAME_CODE_POINT)

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

          k += d == "\\" && source[k + 1] != "\n" ? 2 : 1
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
          if source[i, head.length].casecmp?(head) && (i.zero? || !source[i - 1].match?(NAME_CODE_POINT))
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
    end
  end
end
