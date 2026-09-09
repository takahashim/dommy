# frozen_string_literal: true

module Dommy
  module Internal
    # DOM string offsets are UTF-16 code unit indices, not Unicode code points:
    # `CharacterData.length`, every CharacterData offset/count, and every Range
    # boundary offset into a CharacterData node are measured that way. Ruby's
    # `String#length` and `String#[]` count code points, so an astral character
    # (an emoji, say) is off by one per occurrence — hence this one place where
    # the conversion lives, shared by CharacterData and Range.
    #
    # Spec: https://webidl.spec.whatwg.org/#idl-DOMString
    module Utf16
      module_function

      # The number of UTF-16 code units in `str` (an astral character counts 2).
      def length(str)
        str.encode(Encoding::UTF_16LE).bytesize / 2
      end

      # `count` UTF-16 code units of `str` starting at code unit `offset`.
      # Slicing the UTF-16LE byte buffer keeps astral characters intact for the
      # offsets these APIs actually produce.
      #
      # If the range starts or ends inside a surrogate pair the result would be a
      # lone (unpaired) surrogate. JS strings can hold those; a Ruby UTF-8 String
      # cannot, so re-raise the raw encoding error as a clear, intentional
      # message rather than leaking "\xDF on UTF-16LE" to the caller. This is a
      # Dommy limitation and, since splitting a surrogate pair signals a UTF-16
      # offset bug in the caller, failing loud is deliberate.
      def slice(str, offset, count)
        buf = str.encode(Encoding::UTF_16LE)
        buf.byteslice(offset * 2, count * 2).encode(Encoding::UTF_8, Encoding::UTF_16LE)
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise "cannot split a UTF-16 surrogate pair: the requested range would " \
              "produce a lone surrogate, which Dommy cannot represent"
      end

      # Everything from UTF-16 code unit `offset` to the end of `str`.
      def suffix(str, offset)
        slice(str, offset, length(str) - offset)
      end
    end
  end
end
