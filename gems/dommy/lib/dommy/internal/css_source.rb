# frozen_string_literal: true

require_relative "css_syntax"

module Dommy
  module Internal
    # One piece of CSS text, read the way css-syntax-3 tokenizes it: split,
    # balanced and searched only where structure really is, stepping over every
    # escape, string, url and comment whole (CssSyntax.atom_end). The
    # declaration-block parser and var() substitution read text through it, so
    # they answer those questions the same way.
    #
    # It reads a binary copy of the text, made once: every code point that
    # structures CSS is ASCII, and no byte of a multi-byte UTF-8 character is,
    # so scanning bytes finds exactly what scanning characters would — at O(1)
    # per index, where a UTF-8 String with one non-ASCII character in it
    # indexes characters in O(n). The offsets the readers answer with are byte
    # offsets into that copy, and mean something only to the same CssSource,
    # which turns them back into text (#slice). Between two places that can
    # matter, each reader jumps with a native search rather than stepping a
    # byte at a time, so a long `url(data:…)` is crossed in one search.
    class CssSource
      # Where an escape, a string, a url or a comment may start.
      ATOM_START = %r{[\\"'/uU]}
      # The same, or a bracket opening or closing.
      BRACKET_STOP = %r{[\\"'/uU()\[\]{}]}
      # The same, or one of the characters a piece of text is split or
      # searched at.
      TOP_LEVEL_STOP = {
        ";" => %r{[\\"'/uU()\[\]{};]},
        ":" => %r{[\\"'/uU()\[\]{}:]},
        "," => %r{[\\"'/uU()\[\]{},]},
      }.freeze
      # The same, or what a declaration's value may not hold at its top level.
      DECLARATION_STOP = %r{[\\"'/uU()\[\]{};!]}
      # Where a call of each function #next_function is asked for may start,
      # or an atom.
      FUNCTION_STOP = {"var" => %r{[\\"'/uUvV]}}.freeze
      # The bracket that closes a block each opening one starts.
      CLOSER = {"(" => ")", "[" => "]", "{" => "}"}.freeze

      # `bytes:` is a binary String this CssSource may keep as its copy, in
      # place of `text` — a reader handing on what it has already made.
      def initialize(text = nil, bytes: nil)
        @bytes = bytes || text.to_s.b
      end

      # The length in bytes, the units every offset is in.
      def length = @bytes.bytesize

      # The text between byte offsets `from` and `to`.
      def slice(from, to)
        @bytes.byteslice(from, to - from).force_encoding(Encoding::UTF_8)
      end

      def to_s = slice(0, length)

      # The text split at every top-level `char` — one of `;`, `:` and `,`,
      # outside every escape, string, url, comment and bracket.
      def split_top_level(char)
        parts = []
        start = 0
        while (i = index_top_level(char, start))
          parts << slice(start, i)
          start = i + 1
        end
        parts << slice(start, length)
      end

      # The text split at its first top-level `char`: `[before, after]`, or nil
      # when there is none.
      def partition_top_level(char)
        i = index_top_level(char)
        i && [slice(0, i), slice(i + 1, length)]
      end

      # The next call of the function `name` at or after `from`, outside every
      # escape, string, url and comment: `[start, close]`, where `start` is
      # where its name begins (matched ASCII case-insensitively, and not the
      # tail of a longer name) and `close` is its `)`, or nil when it is never
      # closed. nil when there is no such call.
      def next_function(name, from = 0)
        head = "#{name}("
        stop = FUNCTION_STOP.fetch(name)
        i = from
        while (i = @bytes.index(stop, i))
          if (j = CssSyntax.atom_end(@bytes, i))
            i = j
            next
          end
          if @bytes[i, head.length]&.casecmp?(head) && (i.zero? || !CssSyntax.name_code_point?(@bytes[i - 1]))
            return [i, matching_bracket(i + name.length)]
          end

          i += 1
        end
        nil
      end

      # The offset of the bracket closing the one at `open`, or nil when it is
      # never closed. A bracket closes only a block of its own kind: inside a
      # `(` block, a `]` is a token like any other (css-syntax-3 §5.4.7).
      # Escapes, strings, urls and comments are stepped over.
      def matching_bracket(open)
        blocks = []
        i = open
        while (i = @bytes.index(BRACKET_STOP, i))
          if (j = CssSyntax.atom_end(@bytes, i))
            i = j
            next
          end

          return i if step_block(blocks, @bytes[i]) == :closed && blocks.empty?

          i += 1
        end
        nil
      end

      # Whether the text can stand as a declaration's value, a
      # <declaration-value> (css-syntax-3 §8.2): no `;` or `!` at its top
      # level, and no closing bracket that closes no block — so neither a
      # value handed to setProperty nor a custom property's can end its
      # declaration and start another. Inside a block they are tokens like
      # any other; a block still open at the end is closed by it.
      def declaration_value?
        blocks = []
        i = 0
        while (i = @bytes.index(DECLARATION_STOP, i))
          if (j = CssSyntax.atom_end(@bytes, i))
            i = j
            next
          end

          c = @bytes[i]
          return false if blocks.empty? && (c == ";" || c == "!" || CssSyntax::CLOSING_BRACKETS.include?(c))

          step_block(blocks, c)
          i += 1
        end
        true
      end

      # The text with its comments removed, as a CssSource. A comment is no
      # token, but it does separate the tokens on either side (`1px/**/solid`
      # is two), so one between two non-whitespace characters leaves a space
      # behind. One with whitespace on both sides leaves that whitespace once:
      # the whitespace after it joins the run before it (`1px /* c */ + 2px`
      # is `1px + 2px`).
      def without_comments
        return self unless @bytes.include?("/*")

        out = String.new(encoding: Encoding::BINARY)
        i = 0
        while (k = @bytes.index(ATOM_START, i))
          out << @bytes.byteslice(i, k - i)
          j = CssSyntax.atom_end(@bytes, k)
          if j.nil?
            out << @bytes.byteslice(k, 1)
            i = k + 1
          elsif @bytes[k] == "/"
            i = drop_comment(out, j)
          else
            out << @bytes.byteslice(k, j - k)
            i = j
          end
        end
        out << @bytes.byteslice(i, length - i)
        CssSource.new(bytes: out)
      end

      private

      # The offset of the first top-level `char` at or after `from`, or nil.
      def index_top_level(char, from = 0)
        stop = TOP_LEVEL_STOP.fetch(char)
        blocks = []
        i = from
        while (i = @bytes.index(stop, i))
          if (j = CssSyntax.atom_end(@bytes, i))
            i = j
            next
          end

          c = @bytes[i]
          return i if c == char && blocks.empty?

          step_block(blocks, c)
          i += 1
        end
        nil
      end

      # Track the blocks open at `c`: an opening bracket opens one, and a
      # closing bracket closes the innermost only when it is that block's own
      # kind (:closed); any other closing bracket is a token like any other.
      def step_block(blocks, c)
        if (closer = CLOSER[c])
          blocks.push(closer)
          :opened
        elsif !blocks.empty? && blocks.last == c
          blocks.pop
          :closed
        end
      end

      # The spacing a removed comment leaves in `out`, and where reading
      # resumes after the comment that ended at `j`.
      def drop_comment(out, j)
        before = out[-1]
        after = @bytes[j]
        before_space = before.nil? || CssSyntax::WHITESPACE.include?(before)
        after_space = after.nil? || CssSyntax::WHITESPACE.include?(after)
        if before_space && !before.nil?
          j += 1 while j < length && CssSyntax::WHITESPACE.include?(@bytes[j])
        elsif !before_space && !after_space
          out << " "
        end
        j
      end
    end
  end
end
