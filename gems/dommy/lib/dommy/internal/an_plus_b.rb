# frozen_string_literal: true

module Dommy
  module Internal
    module SelectorParser
      # The An+B microsyntax (css-syntax-3 §9) matched on tokens: the pure half
      # of reading `:nth-child()`'s argument. The selector parser reads the
      # tokens — it owns the cursor, the escapes and the comments — and hands
      # them here; what comes back is `[a, b]`, or InvalidSelector.
      module AnPlusB
        # A token as An+B sees one: :ws, :delim, :ident, :number, :percentage
        # or :dimension, with a number's integer value, whether it was written
        # as an integer, its sign character, and a dimension's unit.
        Token = Struct.new(:type, :value, :integer, :sign, :unit)

        module_function

        # The productions of §9.2, on tokens. Whitespace may separate any two
        # tokens except a `+` and the `n`-ident after it (the † note).
        def match(tokens)
          t = tokens.drop_while { |x| x.type == :ws }.reverse.drop_while { |x| x.type == :ws }.reverse
          invalid! if t.empty?

          plus = t.first.type == :delim && t.first.value == "+"
          if plus
            t.shift
            invalid! unless t.first&.type == :ident
          end
          first = t.shift
          rest = t.drop_while { |x| x.type == :ws }

          case first.type
          when :ident
            v = first.value.downcase(:ascii)
            if !plus && v == "odd" then complete(rest, 2, 1)
            elsif !plus && v == "even" then complete(rest, 2, 0)
            elsif v == "n" then with_b(rest, 1)
            elsif !plus && v == "-n" then with_b(rest, -1)
            elsif v == "n-" then with_signless_b(rest, 1)
            elsif !plus && v == "-n-" then with_signless_b(rest, -1)
            elsif (m = v.match(/\An-([0-9]+)\z/)) then complete(rest, 1, -m[1].to_i)
            elsif !plus && (m = v.match(/\A-n-([0-9]+)\z/)) then complete(rest, -1, -m[1].to_i)
            else invalid!
            end
          when :number
            invalid! unless first.integer

            complete(rest, 0, first.value)
          when :dimension
            invalid! unless first.integer

            u = first.unit.downcase(:ascii)
            if u == "n" then with_b(rest, first.value)
            elsif u == "n-" then with_signless_b(rest, first.value)
            elsif (m = u.match(/\An-([0-9]+)\z/)) then complete(rest, first.value, -m[1].to_i)
            else invalid!
            end
          else
            invalid!
          end
        end

        # The expression is `a`n+`b`, provided nothing follows.
        def complete(rest, a, b)
          invalid! unless rest.empty?

          [a, b]
        end

        # After `An`: nothing, a signed integer, or `+`/`-` and a signless one.
        def with_b(rest, a)
          return [a, 0] if rest.empty?

          head = rest.first
          if head.type == :number && head.integer && head.sign
            complete(rest.drop(1), a, head.value)
          elsif head.type == :delim && (head.value == "+" || head.value == "-")
            signless = rest.drop(1).drop_while { |x| x.type == :ws }
            n = signless.first
            invalid! unless n&.type == :number && n.integer && n.sign.nil?

            complete(signless.drop(1), a, head.value == "-" ? -n.value : n.value)
          else
            invalid!
          end
        end

        # After `An-`: a signless integer, negated.
        def with_signless_b(rest, a)
          n = rest.first
          invalid! unless n&.type == :number && n.integer && n.sign.nil?

          complete(rest.drop(1), a, -n.value)
        end

        def invalid!
          raise InvalidSelector, "invalid An+B expression"
        end

        private_class_method :complete, :with_b, :with_signless_b, :invalid!
      end
    end
  end
end
