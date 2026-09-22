# frozen_string_literal: true

require_relative "tokenizer"

module Dommy
  class URLPattern
    # One piece of a parsed pattern string: fixed text, or a matching group
    # (a custom regexp, a `:name` segment wildcard, or a `*` full wildcard)
    # with the fixed prefix and suffix that belong to it and its modifier
    # ("none", "optional", "zero-or-more" or "one-or-more").
    #
    # Spec: https://urlpattern.spec.whatwg.org/#parts
    Part = Struct.new(:type, :value, :modifier, :name, :prefix, :suffix)

    # How a component reads its pattern: the segment separator a `:name`
    # stops at, the prefix character that binds to a following group (the
    # `/` in `/foo/:bar?`), and case sensitivity.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#options
    Options = Struct.new(:delimiter, :prefix, :ignore_case)

    DEFAULT_OPTIONS = Options.new("", "", false).freeze
    HOSTNAME_OPTIONS = Options.new(".", "", false).freeze
    PATHNAME_OPTIONS = Options.new("/", "/", false).freeze

    # Reads a token list into a part list, and writes a part list back out as
    # the ECMAScript regexp that matches it or as the normalized pattern
    # string the component getters return.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#parsing-pattern-strings
    class PatternParser
      FULL_WILDCARD_REGEXP_VALUE = ".*"

      # Parse `input` with `options`, running `encoding_callback` (a
      # canonicalizer for the component) over every piece of fixed text.
      def self.parse(input, options, encoding_callback)
        new(input, options, encoding_callback).parse
      end

      def self.segment_wildcard_regexp(options)
        "[^#{escape_regexp_string(options.delimiter)}]+?"
      end

      # The characters that mean something in an ECMAScript regexp, escaped.
      def self.escape_regexp_string(input)
        input.gsub(%r{[.+*?^${}()\[\]|/\\]}) { |c| "\\#{c}" }
      end

      # The characters that mean something in a pattern string, escaped.
      def self.escape_pattern_string(input)
        input.gsub(/[+*?:{}()\\]/) { |c| "\\#{c}" }
      end

      def self.modifier_to_string(modifier)
        case modifier
        when "zero-or-more" then "*"
        when "optional" then "?"
        when "one-or-more" then "+"
        else ""
        end
      end

      # The regexp source that matches `parts` and, in parallel, the name of
      # each capturing group it opens.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#generate-a-regular-expression-and-name-list
      def self.regexp_and_names(parts, options)
        result = +"^"
        names = []
        parts.each do |part|
          if part.type == "fixed-text"
            if part.modifier == "none"
              result << escape_regexp_string(part.value)
            else
              result << "(?:" << escape_regexp_string(part.value) << ")" << modifier_to_string(part.modifier)
            end
            next
          end

          names << part.name
          regexp_value = case part.type
          when "segment-wildcard" then segment_wildcard_regexp(options)
          when "full-wildcard" then FULL_WILDCARD_REGEXP_VALUE
          else part.value
          end

          if part.prefix.empty? && part.suffix.empty?
            if part.modifier == "none" || part.modifier == "optional"
              result << "(" << regexp_value << ")" << modifier_to_string(part.modifier)
            else
              result << "((?:" << regexp_value << ")" << modifier_to_string(part.modifier) << ")"
            end
            next
          end

          if part.modifier == "none" || part.modifier == "optional"
            result << "(?:" << escape_regexp_string(part.prefix) << "(" << regexp_value << ")" <<
              escape_regexp_string(part.suffix) << ")" << modifier_to_string(part.modifier)
            next
          end

          # A repeated group with a prefix or suffix: the first repetition
          # comes without them, every later one is joined by suffix + prefix,
          # and the whole thing is optional when zero repetitions are allowed.
          result << "(?:" << escape_regexp_string(part.prefix) << "((?:" << regexp_value << ")(?:" <<
            escape_regexp_string(part.suffix) << escape_regexp_string(part.prefix) << "(?:" << regexp_value <<
            "))*)" << escape_regexp_string(part.suffix) << ")"
          result << "?" if part.modifier == "zero-or-more"
        end
        result << "$"
        [result, names]
      end

      # The normalized pattern string for `parts`: what the pattern would be
      # written as with every group made explicit only where it has to be.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#generate-a-pattern-string
      def self.pattern_string(parts, options)
        result = +""
        parts.each_with_index do |part, index|
          previous_part = index.positive? ? parts[index - 1] : nil
          next_part = index < parts.length - 1 ? parts[index + 1] : nil

          if part.type == "fixed-text"
            if part.modifier == "none"
              result << escape_pattern_string(part.value)
            else
              result << "{" << escape_pattern_string(part.value) << "}" << modifier_to_string(part.modifier)
            end
            next
          end

          custom_name = !part.name[0].match?(/[0-9]/)
          needs_grouping = !part.suffix.empty? || (!part.prefix.empty? && part.prefix != options.prefix)

          if !needs_grouping && custom_name && part.type == "segment-wildcard" && part.modifier == "none" &&
              next_part && next_part.prefix.empty? && next_part.suffix.empty?
            needs_grouping = if next_part.type == "fixed-text"
              Tokenizer.valid_name_code_point?(next_part.value[0], false)
            else
              next_part.name[0].match?(/[0-9]/)
            end
          end

          if !needs_grouping && part.prefix.empty? && previous_part && previous_part.type == "fixed-text" &&
              previous_part.value[-1] == options.prefix
            needs_grouping = true
          end

          result << "{" if needs_grouping
          result << escape_pattern_string(part.prefix)
          result << ":" << part.name if custom_name

          if part.type == "regexp"
            result << "(" << part.value << ")"
          elsif part.type == "segment-wildcard" && !custom_name
            result << "(" << segment_wildcard_regexp(options) << ")"
          elsif part.type == "full-wildcard"
            if !custom_name && (previous_part.nil? || previous_part.type == "fixed-text" ||
                previous_part.modifier != "none" || needs_grouping || !part.prefix.empty?)
              result << "*"
            else
              result << "(" << FULL_WILDCARD_REGEXP_VALUE << ")"
            end
          end

          if part.type == "segment-wildcard" && custom_name && !part.suffix.empty? &&
              Tokenizer.valid_name_code_point?(part.suffix[0], false)
            result << "\\"
          end
          result << escape_pattern_string(part.suffix)
          result << "}" if needs_grouping
          result << modifier_to_string(part.modifier)
        end
        result
      end

      def initialize(input, options, encoding_callback)
        @tokens = Tokenizer.tokenize(input, "strict")
        @options = options
        @encoding_callback = encoding_callback
        @segment_wildcard_regexp = PatternParser.segment_wildcard_regexp(options)
        @parts = []
        @pending_fixed_value = +""
        @index = 0
        @next_numeric_name = 0
      end

      def parse
        while @index < @tokens.length
          # <prefix char><name><regexp><modifier>, any of which may be absent
          char_token = try_consume_token("char")
          name_token = try_consume_token("name")
          regexp_or_wildcard_token = try_consume_regexp_or_wildcard_token(name_token)
          if name_token || regexp_or_wildcard_token
            prefix = char_token ? char_token.value : ""
            if !prefix.empty? && prefix != @options.prefix
              @pending_fixed_value << prefix
              prefix = ""
            end
            maybe_add_part_from_pending_fixed_value
            modifier_token = try_consume_modifier_token
            add_part(prefix, name_token, regexp_or_wildcard_token, "", modifier_token)
            next
          end

          fixed_token = char_token || try_consume_token("escaped-char")
          if fixed_token
            @pending_fixed_value << fixed_token.value
            next
          end

          # <open><char prefix><name><regexp><char suffix><close><modifier>
          open_token = try_consume_token("open")
          if open_token
            prefix = consume_text
            name_token = try_consume_token("name")
            regexp_or_wildcard_token = try_consume_regexp_or_wildcard_token(name_token)
            suffix = consume_text
            consume_required_token("close")
            modifier_token = try_consume_modifier_token
            add_part(prefix, name_token, regexp_or_wildcard_token, suffix, modifier_token)
            next
          end

          maybe_add_part_from_pending_fixed_value
          consume_required_token("end")
        end
        @parts
      end

      private

      def try_consume_token(type)
        next_token = @tokens[@index]
        return nil unless next_token.type == type

        @index += 1
        next_token
      end

      def try_consume_modifier_token
        try_consume_token("other-modifier") || try_consume_token("asterisk")
      end

      def try_consume_regexp_or_wildcard_token(name_token)
        token = try_consume_token("regexp")
        token = try_consume_token("asterisk") if name_token.nil? && token.nil?
        token
      end

      def consume_required_token(type)
        token = try_consume_token(type)
        raise Bridge::TypeError, "Invalid pattern: expected #{type} at token #{@index}" unless token

        token
      end

      def consume_text
        result = +""
        loop do
          token = try_consume_token("char") || try_consume_token("escaped-char")
          break unless token

          result << token.value
        end
        result
      end

      def maybe_add_part_from_pending_fixed_value
        return if @pending_fixed_value.empty?

        encoded_value = @encoding_callback.call(@pending_fixed_value)
        @pending_fixed_value = +""
        @parts << Part.new("fixed-text", encoded_value, "none", "", "", "")
      end

      def add_part(prefix, name_token, regexp_or_wildcard_token, suffix, modifier_token)
        modifier = "none"
        if modifier_token
          modifier = case modifier_token.value
          when "?" then "optional"
          when "*" then "zero-or-more"
          when "+" then "one-or-more"
          else "none"
          end
        end

        # `{foo}`: plain text that joins whatever text is around it.
        if name_token.nil? && regexp_or_wildcard_token.nil? && modifier == "none"
          @pending_fixed_value << prefix
          return
        end

        maybe_add_part_from_pending_fixed_value

        # `{foo}?`: the modifier keeps it apart from the surrounding text.
        if name_token.nil? && regexp_or_wildcard_token.nil?
          return if prefix.empty?

          encoded_value = @encoding_callback.call(prefix)
          @parts << Part.new("fixed-text", encoded_value, modifier, "", "", "")
          return
        end

        regexp_value = if regexp_or_wildcard_token.nil?
          @segment_wildcard_regexp
        elsif regexp_or_wildcard_token.type == "asterisk"
          FULL_WILDCARD_REGEXP_VALUE
        else
          regexp_or_wildcard_token.value
        end

        # A regexp spelled the same as a wildcard is that wildcard.
        type = "regexp"
        if regexp_value == @segment_wildcard_regexp
          type = "segment-wildcard"
          regexp_value = ""
        elsif regexp_value == FULL_WILDCARD_REGEXP_VALUE
          type = "full-wildcard"
          regexp_value = ""
        end

        name = ""
        if name_token
          name = name_token.value
        elsif regexp_or_wildcard_token
          name = @next_numeric_name.to_s
          @next_numeric_name += 1
        end
        raise Bridge::TypeError, "Invalid pattern: duplicate name #{name.inspect}" if duplicate_name?(name)

        encoded_prefix = @encoding_callback.call(prefix)
        encoded_suffix = @encoding_callback.call(suffix)
        @parts << Part.new(type, regexp_value, modifier, name, encoded_prefix, encoded_suffix)
      end

      def duplicate_name?(name)
        @parts.any? { |part| part.name == name }
      end
    end
  end
end
