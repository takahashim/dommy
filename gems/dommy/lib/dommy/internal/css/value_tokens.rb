# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # Splitting a CSS component-value list into its top-level tokens.
      #
      # There is one rule — whitespace separates, except inside parentheses, so
      # `rgb(0, 0, 0)` and `linear-gradient(to right, red)` each stay one token —
      # and it is needed wherever a value is read by hand: shorthand expansion
      # (`border: 1px solid red`), color extraction out of a `background`, box
      # values. It lives here so those callers cannot answer it differently.
      module ValueTokens
        # The four box sides, in the order every CSS box shorthand lists them.
        SIDES = %w[top right bottom left].freeze

        module_function

        def split(value)
          tokens = []
          current = +""
          depth = 0
          value.to_s.each_char do |char|
            case char
            when "("
              depth += 1
              current << char
            when ")"
              depth -= 1 if depth.positive?
              current << char
            when /\s/
              if depth.positive?
                current << char
              elsif !current.empty?
                tokens << current
                current = +""
              end
            else
              current << char
            end
          end
          tokens << current unless current.empty?
          tokens
        end

        # The CSS box shorthand's 1/2/3/4-value expansion, as
        # [top, right, bottom, left]. More than four values keeps the first four
        # (callers reject the count first where the spec says to).
        def box_sides(tokens)
          case tokens.size
          when 1 then [tokens[0]] * 4
          when 2 then [tokens[0], tokens[1], tokens[0], tokens[1]]
          when 3 then [tokens[0], tokens[1], tokens[2], tokens[1]]
          else tokens[0, 4]
          end
        end
      end
    end
  end
end
