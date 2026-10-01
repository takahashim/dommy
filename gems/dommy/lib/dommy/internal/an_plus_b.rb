# frozen_string_literal: true

module Dommy
  module Internal
    module SelectorParser
      # The An+B microsyntax (css-syntax-3 §9) matched on tokens: the pure half
      # of reading `:nth-child()`'s argument. The selector parser reads the
      # tokens — it owns the cursor over the source, the escapes and the
      # comments — and hands them here; what comes back is `[a, b]`, or
      # InvalidSelector. A match is a cursor over those tokens: each production
      # takes what it needs from where the last one stopped.
      class AnPlusB
        # A token as An+B sees one: :ws, :delim, :ident, :number, :percentage
        # or :dimension, with a number's integer value, whether it was written
        # as an integer, its sign character, and a dimension's unit.
        Token = Struct.new(:type, :value, :integer, :sign, :unit)

        def self.match(tokens) = new(tokens).match

        # Whitespace before and after the expression is no part of it.
        def initialize(tokens)
          @tokens = tokens.drop_while { |t| t.type == :ws }.reverse.drop_while { |t| t.type == :ws }.reverse
          @index = 0
        end

        # The productions of §9.2. Whitespace may separate any two tokens
        # except a `+` and the `n`-ident after it (the † note).
        def match
          plus = take_delim?("+")
          first = take
          invalid! if first.nil? || (plus && first.type != :ident)
          skip_ws

          case first.type
          when :ident
            v = first.value.downcase(:ascii)
            if !plus && v == "odd" then complete(2, 1)
            elsif !plus && v == "even" then complete(2, 0)
            elsif v == "n" then with_b(1)
            elsif !plus && v == "-n" then with_b(-1)
            elsif v == "n-" then with_signless_b(1)
            elsif !plus && v == "-n-" then with_signless_b(-1)
            elsif (m = v.match(/\An-([0-9]+)\z/)) then complete(1, -m[1].to_i)
            elsif !plus && (m = v.match(/\A-n-([0-9]+)\z/)) then complete(-1, -m[1].to_i)
            else invalid!
            end
          when :number
            invalid! unless first.integer

            complete(0, first.value)
          when :dimension
            invalid! unless first.integer

            u = first.unit.downcase(:ascii)
            if u == "n" then with_b(first.value)
            elsif u == "n-" then with_signless_b(first.value)
            elsif (m = u.match(/\An-([0-9]+)\z/)) then complete(first.value, -m[1].to_i)
            else invalid!
            end
          else
            invalid!
          end
        end

        private

        # The expression is `a`n+`b`, provided nothing follows.
        def complete(a, b)
          invalid! unless peek.nil?

          [a, b]
        end

        # After `An`: nothing, a signed integer, or `+`/`-` and a signless one.
        def with_b(a)
          return [a, 0] if peek.nil?

          head = take
          if head.type == :number && head.integer && head.sign
            complete(a, head.value)
          elsif head.type == :delim && (head.value == "+" || head.value == "-")
            skip_ws
            n = signless_integer
            complete(a, head.value == "-" ? -n : n)
          else
            invalid!
          end
        end

        # After `An-`: a signless integer, negated.
        def with_signless_b(a) = complete(a, -signless_integer)

        def signless_integer
          n = take
          invalid! unless n&.type == :number && n.integer && n.sign.nil?

          n.value
        end

        def peek = @tokens[@index]

        def take
          token = peek
          @index += 1 if token
          token
        end

        def take_delim?(value)
          return false unless peek&.type == :delim && peek.value == value

          @index += 1
          true
        end

        def skip_ws
          @index += 1 while peek&.type == :ws
        end

        def invalid!
          raise InvalidSelector, "invalid An+B expression"
        end
      end
    end
  end
end
