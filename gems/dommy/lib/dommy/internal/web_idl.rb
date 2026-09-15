# frozen_string_literal: true

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

      def string_to_integer(value)
        float = Float(value.strip.empty? ? "0" : value.strip, exception: false)
        float&.finite? ? float.truncate : 0
      end

      # `value` converted to `Node?`: null and undefined both become nil.
      def nullable_node!(value)
        return nil if value.nil? || value.equal?(Bridge::UNDEFINED)

        node!(value)
      end
    end
  end
end
