# frozen_string_literal: true

module Dommy
  module Internal
    # Definitions from the WHATWG Infra Standard that several specs build on.
    module Infra
      # ASCII whitespace (https://infra.spec.whatwg.org/#ascii-whitespace): TAB,
      # LF, FF, CR, SPACE — NOT Ruby's `\s` (which also matches VT / U+000B) and
      # NOT any Unicode space (U+00A0, U+2000…). Class tokens and `~=` split on
      # exactly this set, so a class of a single U+000B or U+00A0 is ONE token.
      ASCII_WHITESPACE = /[\t\n\f\r ]+/
      ASCII_WHITESPACE_CHARS = "\t\n\f\r "

      module_function

      # Whether the one character `char` is ASCII whitespace.
      def ascii_whitespace?(char)
        !char.nil? && ASCII_WHITESPACE_CHARS.include?(char)
      end

      # `value` split on ASCII whitespace, with no empty tokens.
      def split_on_ascii_whitespace(value)
        value.to_s.split(ASCII_WHITESPACE).reject(&:empty?)
      end
    end
  end
end
