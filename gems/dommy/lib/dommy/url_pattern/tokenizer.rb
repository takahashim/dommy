# frozen_string_literal: true

module Dommy
  class URLPattern
    # One lexical token of a pattern string. `index` is the position of its
    # first code point in the input, `value` the code points it stands for.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#tokens
    Token = Struct.new(:type, :index, :value)

    # Splits a pattern string into tokens: `{` and `}`, a `(regexp)`, a
    # `:name`, a modifier (`?`, `+`, or the `*` that is also the wildcard),
    # a `\` escape, and plain characters. In "strict" mode a malformed
    # regexp or an escape at the end is a TypeError; in "lenient" mode it
    # becomes an "invalid-char" token, which is how the constructor string
    # parser reads a URL-shaped pattern without tripping on its parts.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#tokenizing
    class Tokenizer
      def self.tokenize(input, policy)
        new(input, policy).tokenize
      end

      def initialize(input, policy)
        @input = input
        @chars = input.chars
        @policy = policy
        @tokens = []
        @index = 0
        @next_index = 0
        @code_point = nil
      end

      def tokenize
        while @index < @chars.length
          seek_and_get_next_code_point(@index)
          case @code_point
          when "*"
            add_token_with_default_position_and_length("asterisk")
          when "+", "?"
            add_token_with_default_position_and_length("other-modifier")
          when "\\"
            tokenize_escape
          when "{"
            add_token_with_default_position_and_length("open")
          when "}"
            add_token_with_default_position_and_length("close")
          when ":"
            tokenize_name
          when "("
            tokenize_regexp
          else
            add_token_with_default_position_and_length("char")
          end
        end
        add_token_with_default_length("end", @index, @index)
        @tokens
      end

      # Whether `code_point` may appear in a `:name`: IdentifierStart for the
      # first, IdentifierPart after that, as ECMAScript defines them.
      def self.valid_name_code_point?(code_point, first)
        if first
          code_point.match?(/\A[\p{ID_Start}$_]\z/)
        else
          code_point.match?(/\A[\p{ID_Continue}$\u200c\u200d]\z/)
        end
      end

      private

      def tokenize_escape
        if @index == @chars.length - 1
          process_tokenizing_error(@next_index, @index)
          return
        end
        escaped_index = @next_index
        get_next_code_point
        add_token_with_default_length("escaped-char", @next_index, escaped_index)
      end

      def tokenize_name
        name_position = @next_index
        name_start = name_position
        while name_position < @chars.length
          seek_and_get_next_code_point(name_position)
          first = name_position == name_start
          break unless Tokenizer.valid_name_code_point?(@code_point, first)

          name_position = @next_index
        end
        if name_position <= name_start
          process_tokenizing_error(name_start, @index)
          return
        end
        add_token_with_default_length("name", name_position, name_start)
      end

      def tokenize_regexp
        depth = 1
        regexp_position = @next_index
        regexp_start = regexp_position
        error = false
        while regexp_position < @chars.length
          seek_and_get_next_code_point(regexp_position)
          unless @code_point.ascii_only?
            process_tokenizing_error(regexp_start, @index)
            error = true
            break
          end
          if regexp_position == regexp_start && @code_point == "?"
            process_tokenizing_error(regexp_start, @index)
            error = true
            break
          end
          if @code_point == "\\"
            if regexp_position == @chars.length - 1
              process_tokenizing_error(regexp_start, @index)
              error = true
              break
            end
            get_next_code_point
            unless @code_point.ascii_only?
              process_tokenizing_error(regexp_start, @index)
              error = true
              break
            end
            regexp_position = @next_index
            next
          end
          if @code_point == ")"
            depth -= 1
            if depth.zero?
              regexp_position = @next_index
              break
            end
          elsif @code_point == "("
            depth += 1
            if regexp_position == @chars.length - 1
              process_tokenizing_error(regexp_start, @index)
              error = true
              break
            end
            temporary_position = @next_index
            get_next_code_point
            unless @code_point == "?"
              process_tokenizing_error(regexp_start, @index)
              error = true
              break
            end
            @next_index = temporary_position
          end
          regexp_position = @next_index
        end
        return if error

        if depth != 0
          process_tokenizing_error(regexp_start, @index)
          return
        end
        regexp_length = regexp_position - regexp_start - 1
        if regexp_length.zero?
          process_tokenizing_error(regexp_start, @index)
          return
        end
        add_token("regexp", regexp_position, regexp_start, regexp_length)
      end

      def get_next_code_point
        @code_point = @chars[@next_index]
        @next_index += 1
      end

      def seek_and_get_next_code_point(index)
        @next_index = index
        get_next_code_point
      end

      def add_token(type, next_position, value_position, value_length)
        @tokens << Token.new(type, @index, @chars[value_position, value_length].join)
        @index = next_position
      end

      def add_token_with_default_length(type, next_position, value_position)
        add_token(type, next_position, value_position, next_position - value_position)
      end

      def add_token_with_default_position_and_length(type)
        add_token_with_default_length(type, @next_index, @index)
      end

      def process_tokenizing_error(next_position, value_position)
        raise Bridge::TypeError, "Invalid pattern: #{@input.inspect}" if @policy == "strict"

        add_token_with_default_length("invalid-char", next_position, value_position)
      end
    end
  end
end
