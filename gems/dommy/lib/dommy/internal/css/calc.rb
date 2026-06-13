# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # calc()/min()/max()/clamp() evaluation for the computed-value pipeline,
      # added to PropertyRegistry. Dommy has no layout, so a math function is
      # resolved only when every term reduces to an absolute/font-relative/
      # viewport length or a plain number; a percentage (or any non-reducible
      # part) leaves the function symbolic (evaluate_calc returns nil and the
      # caller keeps the specified value) — matching browsers, which keep such
      # calc()s as-is at computed-value time.
      module PropertyRegistry
        # Raised internally when a sub-expression can't reduce without layout
        # (a %, an unknown unit, a unit clash, or a syntax error).
        class CalcUnresolvable < StandardError; end

        module_function

        def evaluate_calc(value, **ctx)
          value = value.to_s.strip
          return nil unless value.match?(/\A(?:calc|min|max|clamp)\(/i)

          tokens = calc_tokenize(value)
          return nil unless tokens

          parser = CalcParser.new(tokens, ctx)
          kind, number = parser.parse_value
          return nil unless parser.done?

          kind == :length ? format_px(number) : format_number(number)
        rescue CalcUnresolvable
          nil
        end

        # A unitless calc result (e.g. `line-height: calc(1 + 0.5)`), serialized
        # without a unit and without a trailing ".0".
        def format_number(number)
          rounded = number.round(5)
          rounded == rounded.to_i ? rounded.to_i.to_s : rounded.to_s
        end

        # Tokens: "(" ")" "," operators, {num:, unit:}, {fn:} (an ident, only
        # valid before "("). Returns nil on an unexpected character.
        def calc_tokenize(str)
          tokens = []
          index = 0
          length = str.length
          while index < length
            char = str[index]
            if char.match?(/\s/)
              index += 1
            elsif "+-*/(),".include?(char)
              tokens << char
              index += 1
            elsif (match = str[index..].match(/\A(\d*\.\d+|\d+\.?\d*)([a-z%]*)/i))
              tokens << {num: match[1].to_f, unit: match[2].downcase}
              index += match[0].length
            elsif (match = str[index..].match(/\A[a-z]+/i))
              tokens << {fn: match[0].downcase}
              index += match[0].length
            else
              return nil
            end
          end
          tokens
        end
      end

      # Recursive-descent evaluator over calc_tokenize's output. Values are
      # [kind, number] where kind is :length (px) or :number. Operators follow
      # CSS Values 4 calc unit algebra: +/- need matching kinds, * needs a
      # number operand, / needs a number divisor.
      class CalcParser
        def initialize(tokens, ctx)
          @tokens = tokens
          @ctx = ctx
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
            raise PropertyRegistry::CalcUnresolvable
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
            value = combine(name, parse_arguments)
            value
          when "clamp"
            args = parse_arguments
            raise PropertyRegistry::CalcUnresolvable unless args.length == 3

            clamp(*args)
          else
            raise PropertyRegistry::CalcUnresolvable
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
          raise PropertyRegistry::CalcUnresolvable unless kind_a == kind_b

          [kind_a, op == "-" ? num_a - num_b : num_a + num_b]
        end

        def multiply((kind_a, num_a), (kind_b, num_b))
          if kind_b == :number
            [kind_a, num_a * num_b]
          elsif kind_a == :number
            [kind_b, num_a * num_b]
          else
            raise PropertyRegistry::CalcUnresolvable # length * length has no computed unit
          end
        end

        def divide((kind_a, num_a), (kind_b, num_b))
          raise PropertyRegistry::CalcUnresolvable if kind_b != :number || num_b.zero?

          [kind_a, num_a / num_b]
        end

        def combine(name, values)
          kinds = values.map(&:first).uniq
          raise PropertyRegistry::CalcUnresolvable unless kinds.length == 1

          numbers = values.map(&:last)
          [kinds.first, name == "min" ? numbers.min : numbers.max]
        end

        def clamp((kmin, lo), (kval, val), (kmax, hi))
          raise PropertyRegistry::CalcUnresolvable unless [kmin, kval, kmax].uniq.length == 1

          [kval, [[val, hi].min, lo].max]
        end

        def dimension(token)
          unit = token[:unit]
          return [:number, token[:num]] if unit.empty?
          raise PropertyRegistry::CalcUnresolvable if unit == "%"

          px = PropertyRegistry.resolve_length_px("#{token[:num]}#{unit}", **@ctx)
          raise PropertyRegistry::CalcUnresolvable unless px

          [:length, px]
        end

        def peek = @tokens[@pos]

        def advance
          token = @tokens[@pos]
          @pos += 1
          token
        end

        def expect(char)
          raise PropertyRegistry::CalcUnresolvable unless advance == char
        end
      end
    end
  end
end
