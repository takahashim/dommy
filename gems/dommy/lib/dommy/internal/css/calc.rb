# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # calc()/min()/max()/clamp() evaluation. Dommy has no layout, so a math
      # function reduces only when every term is an absolute/font-relative/
      # viewport length or a plain number; a percentage (or any non-reducible
      # part) leaves the function symbolic — #evaluate answers nil and the caller
      # keeps the specified value, which is what browsers serialize too.
      #
      # Self-contained: the font and viewport context belongs to whoever is
      # computing a value, so it arrives as the `length_px` block rather than as
      # a call back into PropertyRegistry.
      module Calc
        # Raised internally when a sub-expression can't reduce without layout
        # (a %, an unknown unit, a unit clash, or a syntax error).
        class Unresolvable < StandardError; end

        FUNCTION = /\A(?:calc|min|max|clamp)\(/i

        module_function

        # [:length, px] or [:number, n] for a reduced math function; nil when
        # `value` is not one, or cannot reduce. `length_px` takes one
        # "<number><unit>" and answers its px magnitude, or nil.
        def evaluate(value, &length_px)
          value = value.to_s.strip
          return nil unless value.match?(FUNCTION)

          tokens = tokenize(value)
          return nil unless tokens

          parser = Parser.new(tokens, length_px)
          result = parser.parse_value
          parser.done? ? result : nil
        rescue Unresolvable
          nil
        end

        # Tokens: "(" ")" "," operators, {num:, unit:}, {fn:} (an ident, only
        # valid before "("). Returns nil on an unexpected character — or when a
        # binary +/- lacks the whitespace CSS Values 4 §10.1 requires on both
        # sides (`1px+1px` is invalid; a unary sign after (/,/operator is fine).
        def tokenize(str)
          tokens = []
          index = 0
          length = str.length
          space_before = true # the opening boundary counts as whitespace
          while index < length
            char = str[index]
            if char.match?(/\s/)
              space_before = true
              index += 1
              next
            end

            if (char == "+" || char == "-") && binary_operator_position?(tokens.last)
              space_after = index + 1 < length && str[index + 1].match?(/\s/)
              return nil unless space_before && space_after

              tokens << char
            elsif "+-*/(),".include?(char)
              tokens << char
            elsif (match = str[index..].match(/\A(\d*\.\d+|\d+\.?\d*)([a-z%]*)/i))
              tokens << {num: match[1].to_f, unit: match[2].downcase}
              index += match[0].length
              space_before = false
              next
            elsif (match = str[index..].match(/\A[a-z]+/i))
              tokens << {fn: match[0].downcase}
              index += match[0].length
              space_before = false
              next
            else
              return nil
            end

            space_before = false
            index += 1
          end
          tokens
        end

        # A +/- is a binary operator (vs a unary sign) when it follows a value:
        # a number/dimension or a closing paren.
        def binary_operator_position?(previous)
          previous == ")" || (previous.is_a?(Hash) && previous.key?(:num))
        end

        # Recursive-descent evaluator over #tokenize's output. Values are
        # [kind, number] where kind is :length (px) or :number. Operators follow
        # CSS Values 4 calc unit algebra: +/- need matching kinds, * needs a
        # number operand, / needs a number divisor.
        class Parser
          def initialize(tokens, length_px)
            @tokens = tokens
            @length_px = length_px
            @pos = 0
          end

          def done? = @pos >= @tokens.length

          # <value> = <function> | ( <sum> ) | [+-] <value> | <dimension>
          def parse_value
            token = peek
            if token.is_a?(Hash) && token[:fn]
              parse_function
            elsif token == "("
              advance
              value = parse_sum
              expect(")")
              value
            elsif token == "+" || token == "-"
              advance
              kind, number = parse_value
              [kind, token == "-" ? -number : number]
            elsif token.is_a?(Hash) && token[:num]
              advance
              dimension(token)
            else
              raise Unresolvable
            end
          end

          private

          def parse_function
            name = advance[:fn]
            expect("(")
            case name
            when "calc"
              value = parse_sum
              expect(")")
              value
            when "min", "max"
              combine(name, parse_arguments)
            when "clamp"
              args = parse_arguments
              raise Unresolvable unless args.length == 3

              clamp(*args)
            else
              raise Unresolvable
            end
          end

          def parse_arguments
            args = [parse_sum]
            while peek == ","
              advance
              args << parse_sum
            end
            expect(")")
            args
          end

          # <sum> = <product> ( ['+'|'-'] <product> )*
          def parse_sum
            value = parse_product
            while peek == "+" || peek == "-"
              op = advance
              value = add(value, parse_product, op)
            end
            value
          end

          # <product> = <value> ( ['*'|'/'] <value> )*
          def parse_product
            value = parse_value
            while peek == "*" || peek == "/"
              op = advance
              value = op == "*" ? multiply(value, parse_value) : divide(value, parse_value)
            end
            value
          end

          def add((kind_a, num_a), (kind_b, num_b), op)
            raise Unresolvable unless kind_a == kind_b

            [kind_a, op == "-" ? num_a - num_b : num_a + num_b]
          end

          def multiply((kind_a, num_a), (kind_b, num_b))
            if kind_b == :number
              [kind_a, num_a * num_b]
            elsif kind_a == :number
              [kind_b, num_a * num_b]
            else
              raise Unresolvable # length * length has no computed unit
            end
          end

          def divide((kind_a, num_a), (kind_b, num_b))
            raise Unresolvable if kind_b != :number || num_b.zero?

            [kind_a, num_a / num_b]
          end

          def combine(name, values)
            kinds = values.map(&:first).uniq
            raise Unresolvable unless kinds.length == 1

            numbers = values.map(&:last)
            [kinds.first, name == "min" ? numbers.min : numbers.max]
          end

          def clamp((kmin, lo), (kval, val), (kmax, hi))
            raise Unresolvable unless [kmin, kval, kmax].uniq.length == 1

            [kval, [[val, hi].min, lo].max]
          end

          def dimension(token)
            unit = token[:unit]
            return [:number, token[:num]] if unit.empty?
            raise Unresolvable if unit == "%"

            px = @length_px.call("#{token[:num]}#{unit}")
            raise Unresolvable unless px

            [:length, px]
          end

          def peek = @tokens[@pos]

          def advance
            token = @tokens[@pos]
            @pos += 1
            token
          end

          def expect(char)
            raise Unresolvable unless advance == char
          end
        end
      end
    end
  end
end
