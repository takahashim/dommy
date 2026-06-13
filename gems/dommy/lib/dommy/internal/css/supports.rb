# frozen_string_literal: true

require_relative "../selector_parser"

module Dommy
  module Internal
    module CSS
      # Evaluator for an `@supports` <supports-condition>. Dommy has no
      # feature-detection database, so a feature query `(prop: value)` is
      # treated optimistically — supported when it is a well-formed declaration
      # — and `selector(s)` is supported when `s` parses as a selector. The
      # boolean combinators (`not` / `and` / `or`) and grouping compose these.
      # This matches a browser for the common case (querying a feature that
      # actually exists); the only divergence is a query about a genuinely
      # unsupported property, which we lean towards "supported" rather than drop
      # the block. Anything unparseable evaluates false. Never raises.
      module Supports
        module_function

        def match?(condition)
          condition = condition.to_s.strip
          return false if condition.empty?

          evaluate_condition(condition)
        rescue StandardError
          false
        end

        # <supports-condition> = not <in-parens>
        #                      | <in-parens> [and <in-parens>]*
        #                      | <in-parens> [or <in-parens>]*
        def evaluate_condition(str)
          str = str.strip
          rest = after_keyword(str, "not")
          return !evaluate_in_parens(rest) if rest

          operands, operator = split_operands(str)
          values = operands.map { |operand| evaluate_in_parens(operand) }
          return values.first if operator.nil?

          operator == "or" ? values.any? : values.all?
        end

        # <in-parens> = ( <condition> ) | ( <declaration> ) | selector(<sel>)
        def evaluate_in_parens(str)
          str = str.strip
          inner = function_argument(str, "selector")
          return selector_supported?(inner) if inner

          return false unless str.start_with?("(") && str.end_with?(")")

          body = str[1...-1].strip
          declaration?(body) ? declaration_supported?(body) : evaluate_condition(body)
        end

        # If `str` begins with `keyword` followed by whitespace, return the
        # remainder; nil otherwise (so `notch` isn't read as `not`).
        def after_keyword(str, keyword)
          return nil unless str.length > keyword.length
          return nil unless str[0, keyword.length].casecmp(keyword).zero?
          return nil unless str[keyword.length].match?(/\s/)

          str[keyword.length..].strip
        end

        # Split a condition into its top-level operands and the joining
        # operator ("and"/"or"/nil). Mixing `and` and `or` at one level is
        # invalid per spec — raise (match? maps it to false).
        def split_operands(str)
          operands = []
          operators = []
          depth = 0
          start = 0
          index = 0
          length = str.length

          while index < length
            char = str[index]
            if char == "("
              depth += 1
              index += 1
            elsif char == ")"
              depth -= 1
              index += 1
            elsif depth.zero? && (keyword = operator_at(str, index))
              operands << str[start...index].strip
              operators << keyword
              index += keyword.length
              start = index
            else
              index += 1
            end
          end
          operands << str[start..].strip

          distinct = operators.uniq
          raise "mixed @supports combinators" if distinct.length > 1

          [operands, distinct.first]
        end

        # "and"/"or" at `index` when it stands as a whole word (whitespace
        # before, whitespace or `(` after).
        def operator_at(str, index)
          return nil unless index.positive? && str[index - 1].match?(/\s/)

          %w[and or].each do |keyword|
            next unless str[index, keyword.length]&.casecmp(keyword)&.zero?

            after = str[index + keyword.length]
            return keyword if after.nil? || after.match?(/\s/) || after == "("
          end
          nil
        end

        # The argument of `name(...)` when `str` is exactly that call, else nil.
        def function_argument(str, name)
          return nil unless str.downcase.start_with?("#{name}(") && str.end_with?(")")

          str[(name.length + 1)...-1].strip
        end

        # A declaration body is `ident : value` (vs a nested condition, which
        # starts with `(`, `not`, or a function).
        def declaration?(body)
          body.match?(/\A[-\w]+\s*:/)
        end

        # Optimistic: a declaration is "supported" when it has a property name
        # and a non-empty value. (No feature database to consult.)
        def declaration_supported?(body)
          name, value = body.split(":", 2)
          !name.to_s.strip.empty? && !value.to_s.strip.empty?
        end

        def selector_supported?(selector_text)
          SelectorParser.parse!(selector_text)
          true
        rescue DOMException::SyntaxError
          false
        end
      end
    end
  end
end
