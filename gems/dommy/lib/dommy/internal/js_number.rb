# frozen_string_literal: true

module Dommy
  module Internal
    # ECMAScript's Number::toString(x) with radix 10 — what JS's `String(x)`
    # gives, and what HTML calls "the best representation of the number as a
    # floating-point number" (the string a double reflection, a meter or a
    # number input writes). Ruby's Float#to_s picks the same shortest
    # round-trip digits but lays them out differently ("1.0e-10", "5.0",
    # "1.0e+16"), so this re-lays them out by the ECMAScript rules:
    #
    #   to_string(5.0)    # => "5"
    #   to_string(-0.0)   # => "0"
    #   to_string(1e21)   # => "1e+21"
    #   to_string(1e-7)   # => "1e-7"
    #   to_string(1.5e-6) # => "0.0000015"
    #   to_string(1e25)   # => "1e+25"
    #
    # Spec: https://tc39.es/ecma262/#sec-numeric-types-number-tostring
    module JsNumber
      module_function

      def to_string(number)
        x = Float(number)
        return "NaN" if x.nan?
        return x.positive? ? "Infinity" : "-Infinity" if x.infinite?
        return "0" if x.zero? # +0 and -0 alike
        return "-#{to_string(-x)}" if x.negative?

        digits, n = shortest_digits(x)
        k = digits.length
        if k <= n && n <= 21
          digits + ("0" * (n - k))
        elsif n.positive? && n <= 21
          "#{digits[0, n]}.#{digits[n..]}"
        elsif n > -6 && n <= 0
          "0.#{"0" * -n}#{digits}"
        else
          exponent = n - 1
          sign = exponent.negative? ? "-" : "+"
          mantissa = k == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
          "#{mantissa}e#{sign}#{exponent.abs}"
        end
      end

      # [s, n] for a finite positive x: the shortest digit string s (no leading
      # or trailing zeros) with x = 0.s × 10^n — ECMAScript's k digits and n.
      # Float#to_s already chose the digits; this only reads them back out.
      def shortest_digits(x)
        mantissa, exponent = x.to_s.split("e")
        int_part, frac_part = mantissa.split(".")
        all = int_part + frac_part.to_s
        point = int_part.length + exponent.to_i
        stripped = all.sub(/\A0+/, "")
        point -= all.length - stripped.length
        [stripped.sub(/0+\z/, ""), point]
      end
    end
  end
end
