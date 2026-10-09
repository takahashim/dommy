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

      # ASCII lowercase (https://infra.spec.whatwg.org/#ascii-lowercase): A-Z
      # to a-z and nothing else, which is how HTML folds an attribute or tag
      # name and how a quirks-mode document folds an id or class. Ruby's
      # `downcase` would fold `\u00c4` too, making it the same name as
      # `\u00e4`.
      def ascii_lowercase(value)
        value.to_s.downcase(:ascii)
      end
    end
  end
end
