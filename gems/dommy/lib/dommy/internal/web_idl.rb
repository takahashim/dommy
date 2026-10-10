# frozen_string_literal: true

require "date"

module Dommy
  module Internal
    # WebIDL argument conversion for interface types. A JS value reaches a host
    # method before any of the method's steps run, and converting it to an
    # interface type (`Node`, `Range`) fails with a TypeError when the value does
    # not implement that interface — null and undefined included, unless the
    # type is nullable. Checking that here, at the entry of each method, keeps a
    # null from travelling into the algorithm and surfacing later as some other
    # exception, or as no exception at all.
    #
    # Spec: https://webidl.spec.whatwg.org/#js-interface
    module WebIDL
      module_function

      # `value` converted to the interface type `interface`.
      def interface!(value, interface)
        return value if value.is_a?(interface)

        raise Bridge::TypeError, "value is not of type '#{interface.name.split("::").last}'."
      end

      # `value` converted to `boolean` (JS ToBoolean): false for false, null,
      # undefined, +0, -0, NaN and "", true for anything else. The bridge hands
      # JS NaN over as a Float NaN or as the symbol :NaN.
      def boolean(value)
        return false if value.nil? || value == false || value.equal?(Bridge::UNDEFINED)
        return false if value.is_a?(Numeric) && (value.zero? || (value.is_a?(Float) && value.nan?))
        return false if value == :NaN || value == ""

        true
      end

      # `value` converted to `Node`.
      def node!(value)
        interface!(value, Dommy::Node)
      end

      # `value` converted to `unsigned long`: ToNumber, then NaN and ±Infinity
      # become 0, and anything else truncates toward zero and wraps modulo 2^32
      # (so -1 is 4294967295).
      def unsigned_long(value)
        number =
          case value
          when Integer then value
          when Float then value.finite? ? value.truncate : 0
          when true then 1
          when String then string_to_integer(value)
          else 0 # null, false, undefined, NaN
          end
        number % (2**32)
      end

      # `value` converted to `long`: ToNumber, then NaN and ±Infinity become
      # 0, and anything else truncates toward zero and wraps into the signed
      # 32-bit range (so 2**32 + 1 is 1 and 2**31 is -2**31).
      def long(value)
        number = unrestricted_double(value)
        return 0 unless number.finite?

        wrapped = number.truncate % (2**32)
        wrapped >= 2**31 ? wrapped - (2**32) : wrapped
      end

      def string_to_integer(value)
        float = Float(value.strip.empty? ? "0" : value.strip, exception: false)
        float&.finite? ? float.truncate : 0
      end

      # `value` converted to `Node?`: null and undefined both become nil.
      def nullable_node!(value)
        return nil if value.nil? || value.equal?(Bridge::UNDEFINED)

        node!(value)
      end

      # `value` converted to `unrestricted double` (JS ToNumber): NaN and the
      # infinities pass through. The bridge hands JS NaN over as the symbol
      # :NaN; a Date is its time value. An object Ruby cannot ask for a
      # primitive is NaN.
      def unrestricted_double(value)
        case value
        when Numeric then value.to_f
        when nil, false then 0.0
        when true then 1.0
        when String then string_to_double(value)
        when Bridge::Date then value.time_value
        else ::Float::NAN # undefined, NaN, other objects
        end
      end

      # JS StringToNumber for the decimal forms: surrounding whitespace is
      # ignored and the empty string is 0.
      def string_to_double(value)
        text = value.strip
        return 0.0 if text.empty?
        return ::Float::INFINITY if text == "Infinity" || text == "+Infinity"
        return -::Float::INFINITY if text == "-Infinity"

        Float(text, exception: false)&.to_f || ::Float::NAN
      end

      # `value` converted to `DOMString` (JS ToString) as the bridge hands it
      # over: a JS object arrives as a Hash, an array as an Array, NaN as a
      # Float NaN or the symbol :NaN.
      def dom_string(value)
        case value
        when String then value
        when nil then "null"
        when true then "true"
        when false then "false"
        when Hash then "[object Object]"
        when Array then value.map { |element| element.nil? || element.equal?(Bridge::UNDEFINED) ? "" : dom_string(element) }.join(",")
        when Integer then value.to_s
        when Float then number_to_string(value)
        when :NaN then "NaN"
        else value.equal?(Bridge::UNDEFINED) ? "undefined" : value.to_s
        end
      end

      # ECMAScript Number::toString(x) in base 10: the shortest digits that
      # round-trip (which Ruby's Float#to_s also finds), laid out as JS does —
      # plain up to 21 integer digits, `0.000001` down to 6 leading zeros,
      # `1e+21` / `1e-7` beyond, and no `.0` on an integral value.
      def number_to_string(x)
        return "NaN" if x.nan?
        return x.positive? ? "Infinity" : "-Infinity" if x.infinite?
        return "0" if x.zero?
        return "-#{number_to_string(-x)}" if x.negative?

        mantissa, exponent = x.to_s.split("e")
        integer, fraction = mantissa.split(".")
        all = integer + fraction.to_s
        leading = all[/\A0*/].size
        digits = all[leading..].sub(/0+\z/, "")
        k = digits.size
        n = integer.size - leading + exponent.to_i
        if k <= n && n <= 21
          digits + ("0" * (n - k))
        elsif n.positive? && n <= 21
          "#{digits[0, n]}.#{digits[n..]}"
        elsif n > -6 && n <= 0
          "0.#{"0" * -n}#{digits}"
        else
          e = n - 1
          sign = e.negative? ? "-" : "+"
          head = k == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
          "#{head}e#{sign}#{e.abs}"
        end
      end

      # `value` converted to `object?`: null and undefined become nil, and a
      # primitive is a TypeError.
      def nullable_object!(value)
        return nil if value.nil? || value.equal?(Bridge::UNDEFINED)
        if value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol) || value == true || value == false
          raise Bridge::TypeError, "value is not of type 'object'."
        end

        value
      end

      # The time value (ms since the epoch, NaN for an invalid date) of a Date
      # object, or nil when `value` is not one. A Ruby ::Time stands in for a
      # Date, as does a ::Date (its UTC midnight).
      def date_time_value(value)
        case value
        when Bridge::Date then value.time_value
        when ::Time then Bridge::Date.time_value_of(value)
        when ::DateTime then date_time_value(value.to_time)
        when ::Date then ::Time.utc(value.year, value.month, value.day).to_i * 1000.0
        end
      end
    end
  end
end
