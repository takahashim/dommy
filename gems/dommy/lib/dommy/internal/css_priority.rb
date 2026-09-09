# frozen_string_literal: true

module Dommy
  module Internal
    # CSSOM `setProperty(property, value, priority)` step 4: the priority
    # argument is valid only when it is the empty string or an ASCII
    # case-insensitive match for "important" — anything else (a typo, a stray
    # "!", surrounding whitespace) makes the whole call a no-op rather than
    # silently dropping the flag.
    #
    # WebIDL declares the argument as
    # `optional [LegacyNullToEmptyString] CSSOMString priority = ""`, so JS null
    # AND an omitted argument both mean the empty string.
    #
    # Spec: https://drafts.csswg.org/cssom/#dom-cssstyledeclaration-setproperty
    module CssPriority
      IMPORTANT = "important"

      module_function

      # "important" / "" for a valid priority, nil when the call must be
      # abandoned without touching the declaration block.
      def normalize(priority)
        return "" if priority.nil? || (defined?(Bridge::UNDEFINED) && priority.equal?(Bridge::UNDEFINED))

        text = priority.to_s
        return "" if text.empty?

        text.casecmp?(IMPORTANT) ? IMPORTANT : nil
      end
    end
  end
end
