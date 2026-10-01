# frozen_string_literal: true

require_relative "infra"

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
    #
    # Two ways in. The index-level readers (#atom_end, #matching_bracket,
    # #next_function) take a String and an index into it and answer in the same
    # units, whatever they are: the selector parser hands its own source and
    # character indices. The text-level ones (#split_top_level,
    # #partition_top_level, #strip_comments) take text and answer in text, and
    # read a binary copy of it inside: every code point that structures CSS is
    # ASCII, and no byte of a multi-byte UTF-8 character is, so scanning bytes
    # finds exactly what scanning characters would — at O(1) per index, where
    # a UTF-8 String with one non-ASCII character in it indexes characters in
    # O(n). The var() readers do the same through #binary and #slice_text. Between
    # two places that can matter, each reader jumps with a native search
    # rather than stepping character by character, so a long `url(data:…)` is
    # crossed in one search.
    module CssSource
      OPENING_BRACKETS = "([{"
      CLOSING_BRACKETS = ")]}"
      # css-syntax-3's whitespace (§4.2) — before §3.3's preprocessing folds CR
      # and FF into LF, the same set as Infra's ASCII whitespace.
      WHITESPACE = Infra::ASCII_WHITESPACE_CHARS
      # css-syntax-3 §4.2 "non-ASCII ident code point". Not everything from
      # U+0080 up: the spec narrowed it to this list, aligned with HTML's valid
      # custom element name. U+2603 SNOWMAN falls between two of the ranges, so
      # it cannot be written into a selector at all except escaped (`.\2603 `).
      NON_ASCII_IDENT_RANGES = [
        0xB7..0xB7, 0xC0..0xD6, 0xD8..0xF6, 0xF8..0x37D, 0x37F..0x1FFF,
        0x200C..0x200D, 0x203F..0x2040, 0x2070..0x218F, 0x2C00..0x2FEF,
        0x3001..0xD7FF, 0xF900..0xFDCF, 0xFDF0..0xFFFD,
      ].freeze

      # Where an escape, a string, a url or a comment may start.
      ATOM_START = %r{[\\"'/uU]}
      # Where an escape, a string, a url or a comment may start, or a bracket
      # opens or closes.
      BRACKET_STOP = %r{[\\"'/uU()\[\]{}]}
      # The same, or one of the characters a block is split or searched at.
      TOP_LEVEL_STOP = {
        ";" => %r{[\\"'/uU()\[\]{};]},
        ":" => %r{[\\"'/uU()\[\]{}:]},
        "," => %r{[\\"'/uU()\[\]{},]},
      }.freeze
      # What can end a string, or must be stepped over in one.
      STRING_STOP = {'"' => /["\\\n]/, "'" => /['\\\n]/}.freeze
      # What can end an unquoted url, or must be stepped over in one.
      URL_STOP = /[)\\]/
      # css-syntax-3 §3.3: the newline forms and NULL the tokenizer never sees.
      NEEDS_FILTERING = /[\r\f\u0000]/

      module_function

      # css-syntax-3 §3.3 "filter code points", the pass that runs before the
      # tokenizer sees anything: the three newline forms become U+000A, and
      # U+0000 becomes U+FFFD. Without it, a backslash before a CRLF escapes
      # the CR and leaves the LF to end the string, as no browser reads it.
      # The replacement character is itself an ident code point, so `.a<NUL>b`
      # names the class `a<U+FFFD>b` rather than being a syntax error.
      def preprocess(text)
        return text unless text.match?(NEEDS_FILTERING)

        text.gsub(/\r\n|[\r\f]/, "\n").gsub("\u0000", "\uFFFD")
      end

      # `text` as the binary String the index-level readers walk in O(1) per
      # byte. Offsets into it are byte offsets; #slice_text reads them back.
      def binary(text) = text.b

      # The text between byte offsets `from` and `to` of `bytes` (see #binary).
      def slice_text(bytes, from, to)
        bytes.byteslice(from, to - from).force_encoding(Encoding::UTF_8)
      end

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

      # A single byte of a binary String at or above 0x80 is part of a
      # non-ASCII character that a byte-level reader cannot see whole; it is
      # taken for a name code point, which only decides whether a `url(` or
      # `var(` after it is the tail of a longer name.
      def non_ascii_ident_code_point?(c)
        codepoint = c.ord
        return false if codepoint < 0x80
        return true if c.bytesize == 1 || codepoint >= 0x10000

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
          string_end(source, j + 1, c)
        elsif c == "/" && source[j + 1] == "*"
          close = source.index("*/", j + 2)
          close ? close + 2 : source.length
        end
      end

      # Index just past the `quote` closing a string whose contents start at
      # `k`, or of the newline that ends it unclosed, or the end of the input.
      # A backslash takes the code point after it (§4.3.5).
      def string_end(source, k, quote)
        stop = STRING_STOP[quote]
        while (k = source.index(stop, k))
          d = source[k]
          return k + 1 if d == quote
          return k if d == "\n"

          k += 2
        end
        source.length
      end

      # Where an unquoted url token's contents start, if the ident `url`
      # (ASCII case-insensitive, not the tail of a longer name) followed by
      # `(` starts at `j` — after the whitespace the url skips. A quote there
      # makes it a `url(` function holding a string instead (§4.3.4).
      def url_contents_start(source, j)
        return nil unless source[j, 4]&.casecmp?("url(")
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
        while (k = source.index(URL_STOP, k))
          return k + 1 if source[k] == ")"

          k += valid_escape_at?(source, k) ? 2 : 1
        end
        source.length
      end

      # The index of the first `char` (one of TOP_LEVEL_STOP's) at or after
      # `from` that is outside every escape, string, url, comment and
      # bracket, or nil.
      def index_top_level(source, char, from = 0)
        stop = TOP_LEVEL_STOP.fetch(char)
        depth = 0
        i = from
        while (i = source.index(stop, i))
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
        stop = Regexp.union(ATOM_START, /#{Regexp.escape(name[0])}/i)
        i = from
        while (i = source.index(stop, i))
          if (j = atom_end(source, i))
            i = j
            next
          end
          if source[i, head.length]&.casecmp?(head) && (i.zero? || !name_code_point?(source[i - 1]))
            return [i, matching_bracket(source, i + name.length)]
          end

          i += 1
        end
        nil
      end

      # The index of the bracket closing the one at `open`, or nil when it is
      # never closed. Every kind of bracket opens a level, and escapes, strings,
      # urls and comments are stepped over.
      def matching_bracket(source, open)
        depth = 0
        i = open
        while (i = source.index(BRACKET_STOP, i))
          if (j = atom_end(source, i))
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

      # `source` split at every top-level `char` (see #index_top_level).
      def split_top_level(source, char)
        bytes = binary(source)
        parts = []
        start = 0
        while (i = index_top_level(bytes, char, start))
          parts << slice_text(bytes, start, i)
          start = i + 1
        end
        parts << slice_text(bytes, start, bytes.bytesize)
      end

      # `source` split at its first top-level `char`: `[before, after]`, or nil
      # when there is none.
      def partition_top_level(source, char)
        bytes = binary(source)
        i = index_top_level(bytes, char)
        i && [slice_text(bytes, 0, i), slice_text(bytes, i + 1, bytes.bytesize)]
      end

      # `source` with its comments removed. A comment is no token, but it does
      # separate the tokens on either side (`1px/**/solid` is two), so one
      # between two non-whitespace characters leaves a space behind. One with
      # whitespace on both sides leaves that whitespace once: the whitespace
      # after it joins the run before it (`1px /* c */ + 2px` is `1px + 2px`).
      def strip_comments(source)
        return source unless source.include?("/*")

        bytes = binary(source)
        out = String.new(encoding: Encoding::BINARY)
        i = 0
        while (k = bytes.index(ATOM_START, i))
          out << bytes.byteslice(i, k - i)
          j = atom_end(bytes, k)
          if j.nil?
            out << bytes.byteslice(k, 1)
            i = k + 1
          elsif bytes[k] == "/"
            j = drop_comment(bytes, out, j)
            i = j
          else
            out << bytes.byteslice(k, j - k)
            i = j
          end
        end
        out << bytes.byteslice(i, bytes.bytesize - i)
        out.force_encoding(Encoding::UTF_8)
      end

      # The spacing a removed comment leaves in `out`, and where reading
      # resumes after the comment that ended at `j`.
      def drop_comment(bytes, out, j)
        before = out[-1]
        after = bytes[j]
        before_space = before.nil? || WHITESPACE.include?(before)
        after_space = after.nil? || WHITESPACE.include?(after)
        if before_space && !before.nil?
          j += 1 while j < bytes.bytesize && WHITESPACE.include?(bytes[j])
        elsif !before_space && !after_space
          out << " "
        end
        j
      end

      private_class_method :non_ascii_ident_code_point?, :string_end, :url_contents_start, :url_end,
        :index_top_level, :drop_comment
    end
  end
end
