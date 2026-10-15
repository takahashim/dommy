# frozen_string_literal: true

require_relative "infra"

module Dommy
  module Internal
    # css-syntax-3's rules for reading CSS source by hand without mistaking the
    # inside of a token for structure. Nothing here holds state: each rule
    # takes a String and an index into it and answers in the same units, so
    # the selector parser asks them with its own source and character indices,
    # and CssSource asks them with byte offsets into its binary copy.
    #
    # css-syntax-3 reads tokens, and four of them carry characters that look
    # like structure but are not: an escape (`\;`, `\,`, `\)` belong to an
    # ident, §4.3.8), a string (its `;`, `:` and `,` are its value, §4.3.5),
    # an unquoted url (`url(a/*b.png)` and `url(it's.png)` hold no comment and
    # no string, §4.3.6), and a comment (no token at all, §4.3.2). #atom_end
    # steps over any of them whole.
    module CssSyntax
      OPENING_BRACKETS = "([{"
      CLOSING_BRACKETS = ")]}"
      # The mirror each opening bracket's block (or function) closes at.
      CLOSER = {"(" => ")", "[" => "]", "{" => "}"}.freeze
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
      # What can end a string, or must be stepped over in one.
      STRING_STOP = {'"' => /["\\\n]/, "'" => /['\\\n]/}.freeze
      # What can end an unquoted url, or must be stepped over in one.
      URL_STOP = /[)\\]/
      # What makes an unquoted url bad (§4.3.6), whitespace and escapes aside:
      # a quote, a `(`, or a non-printable code point (§4.2).
      BAD_URL_CODE_POINT = /["'(\u0000-\u0008\u000B\u000E-\u001F\u007F]/
      # css-syntax-3 §3.3: the newline forms and NULL the tokenizer never sees.
      NEEDS_FILTERING = /[\r\f\u0000]/

      class << self
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

        # Whether the string or unquoted url starting at `j` is a bad one: a
        # <bad-string-token>, which a newline ends unclosed (§4.3.5), or a
        # <bad-url-token> (§4.3.6). No grammar takes either, not even
        # <any-value>.
        def bad_token_at?(source, j)
          c = source[j]
          if (c == "u" || c == "U") && (k = url_contents_start(source, j))
            bad_url?(source, k)
          elsif c == '"' || c == "'"
            k = string_stop(source, j + 1, c)
            !k.nil? && source[k] == "\n"
          else
            false
          end
        end

        private

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

        # Index just past the `quote` closing a string whose contents start at
        # `k`, or of the newline that ends it unclosed, or the end of the input.
        # A backslash takes the code point after it (§4.3.5).
        def string_end(source, k, quote)
          k = string_stop(source, k, quote)
          return source.length if k.nil?

          source[k] == quote ? k + 1 : k
        end

        # Index of the `quote` closing a string whose contents start at `k`, or
        # of the newline that ends it unclosed; nil if the input ends first.
        def string_stop(source, k, quote)
          stop = STRING_STOP[quote]
          while (k = source.index(stop, k))
            return k unless source[k] == "\\"

            k += 2
          end
          nil
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

        # Whether the unquoted url whose contents start at `k` is bad (§4.3.6):
        # whitespace before anything but its `)` or the end of the input, a
        # BAD_URL_CODE_POINT, or a backslash that starts no valid escape.
        def bad_url?(source, k)
          while k < source.length
            c = source[k]
            return false if c == ")"

            if WHITESPACE.include?(c)
              k += 1 while k < source.length && WHITESPACE.include?(source[k])
              return k < source.length && source[k] != ")"
            end
            return true if c.match?(BAD_URL_CODE_POINT)

            if c == "\\"
              return true unless valid_escape_at?(source, k)

              k = escape_end(source, k)
            else
              k += 1
            end
          end
          false
        end

        # Index just past the valid escape whose backslash is at `j` (§4.3.7):
        # up to six hex digits and one whitespace after them, or else the one
        # code point after the backslash.
        def escape_end(source, j)
          hex = source[j + 1, 6].to_s[/\A\h+/]
          return [j + 2, source.length].min if hex.nil?

          k = j + 1 + hex.length
          k += 1 if k < source.length && WHITESPACE.include?(source[k])
          k
        end
      end
    end
  end
end
